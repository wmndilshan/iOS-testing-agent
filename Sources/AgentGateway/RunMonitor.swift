import Foundation
import AgentCore
import AgentInfrastructure

/// Runs one case through the command line tool and turns its `@@EVENT` lines into progress and a result. It answers the runner's questions
/// without a person: the password from the server's environment, a username from the call, an approval only when destructive steps were allowed.
struct RunMonitor: Sendable {
    let services: GatewayServices
    let launcher: any CaseRunLaunching
    /// A run that has not finished in this long is stopped; a case is minutes, not hours.
    var limit: TimeInterval = 3600

    func run(arguments: [String], key: String, progress: GatewayProgress) async -> GatewayResult {
        let handle: any CaseRunHandle
        do { handle = try launcher.launch(arguments: arguments) } catch { return .error(error.localizedDescription) }
        let deadline = Task { try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000)); handle.terminate() }
        defer { deadline.cancel() }
        // A cancelled call (the client no longer wants the answer) stops the runner instead of leaving it on the device.
        return await withTaskCancellationHandler(operation: { await consume(handle, key: key, progress: progress) }, onCancel: { handle.terminate() })
    }

    private func consume(_ handle: any CaseRunHandle, key: String, progress: GatewayProgress) async -> GatewayResult {
        var total = 0, finished = 0
        var rows: [String: String] = [:]
        var order: [String] = []
        var done: [String: Any] = [:]
        var unanswered: [String] = []
        var waits: [String] = []
        var choices: [String] = []
        var tail: [String] = []
        for await line in handle.lines {
            guard line.hasPrefix("@@EVENT "), let data = line.dropFirst(8).data(using: .utf8), let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = event["t"] as? String else {
                tail.append(line)
                if tail.count > 8 { tail.removeFirst() }
                continue
            }
            switch type {
            case "case":
                total = (event["steps"] as? [[String: Any]])?.count ?? 0
                progress("Running \(key): \(event["title"] as? String ?? "") (\(total) steps)", 0)
            case "row":
                guard let id = event["id"] as? String else { break }
                let status = event["status"] as? String ?? ""
                let number = event["number"] as? Int ?? 0
                if rows[id] == nil { order.append(id) }
                rows[id] = "step \(number) [\(status)] \(event["intent"] as? String ?? "")" + ((event["detail"] as? String).map { $0.isEmpty ? "" : " — \($0.prefix(200))" } ?? "")
                if status == "passed" || status == "failed" { finished += 1 }
                progress(rows[id] ?? "", total > 0 ? min(1, Double(finished) / Double(total)) : nil)
            case "prompt" where event["kind"] as? String == "choice":
                // A choice (a name that already exists): nobody is here to pick, so the runner takes its suggestion and says so.
                choices.append(event["title"] as? String ?? "a choice")
                progress("\(event["title"] as? String ?? "A choice came up"): the run takes its suggested value.", nil)
                handle.send("")
            case "guidance":
                if let text = event["text"] as? String, !text.isEmpty { progress("Guidance in use: \(text)", nil) }
            case "prompt":
                let answer = answer(to: event)
                if answer.isEmpty {
                    unanswered.append(event["title"] as? String ?? "input")
                    progress("WAITING FOR THE USER: \(event["title"] as? String ?? "input") — the run needs a person. Tell them.", nil)
                }
                handle.send(answer)
            case "waiting":
                // The runner is holding for something only a person can do (a login on the simulator). Say so; it stops after its timeout.
                waits.append(event["title"] as? String ?? "user action")
                progress("WAITING FOR THE USER: \(event["message"] as? String ?? event["title"] as? String ?? "user action") (stops after \(event["timeout"] as? Int ?? 600) s). Tell the user now.", nil)
            case "waiting-done":
                progress("The wait ended: \(event["result"] as? String ?? "done").", nil)
            case "done": done = event
            default: break
            }
        }
        guard !done.isEmpty else {
            // The runner prints "✗ <reason>" when it cannot start (no idb, no model key, no simulator): that line is the answer.
            let reason = tail.last { $0.hasPrefix("✗") }.map { "The run could not start: " + $0.dropFirst(2) }
            return .error((reason ?? "The run ended without a result.") + "\n" + tail.joined(separator: "\n"))
        }
        let outcome = done["outcome"] as? String ?? "UNKNOWN"
        var lines = ["\(key): \(outcome) — passed \(done["passed"] as? Int ?? 0), failed \(done["failed"] as? Int ?? 0), skipped \(done["skipped"] as? Int ?? 0)"]
        lines += order.compactMap { rows[$0] }
        if !unanswered.isEmpty {
            lines.append("The run asked for input it could not get: \(unanswered.joined(separator: ", ")). Set TEST_USER_USERNAME and TEST_USER_PASSWORD in the server's environment, or pass username.")
        }
        if !choices.isEmpty { lines.append("The runner chose for itself (\(choices.joined(separator: ", "))); its guidance is in the report. To use another value, run again with guidance such as \"use Test9 instead of Test1\".") }
        if !waits.isEmpty { lines.append("The run waited for the user (\(waits.joined(separator: ", "))). If it timed out, ask the user to do that on the simulator, then run the case again.") }
        if let latest = RunReports.all(in: services.caseRunsDirectory).first(where: { $0.report.testKey == key }) { lines.append("Run id: \(latest.id) (get_report for details)") }
        return GatewayResult(content: [.text(lines.joined(separator: "\n"))], isError: outcome != "PASSED")
    }

    /// The runner's question, answered from what the caller gave the server; an empty answer means "could not answer".
    func answer(to prompt: [String: Any]) -> String {
        let id = prompt["id"] as? String ?? ""
        let kind = prompt["kind"] as? String ?? ""
        if kind == "approval" { return "deny" }
        if id == "password" { return services.environment["TEST_USER_PASSWORD"] ?? "" }
        if id == "username" { return services.environment["TEST_USER_USERNAME"] ?? "" }
        return ""
    }
}
