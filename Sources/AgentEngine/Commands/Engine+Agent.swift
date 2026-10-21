import Foundation
import AgentCore
import AgentInfrastructure

// `--agent --repo=<dir> [--provider=deepseek|gemini] [--model=<name>] [--flow=<AgentFlow JSON>] [--scenario="..."]`
//
// A conversation with a team of agents. The app (or a terminal) sends `{"t":"user","text":"..."}` lines on stdin; every thought, tool
// call, hand-off and answer is printed as an `@@EVENT` line. The repository is only read. A case is only run after the person
// approves, and the app does the run through the same runner as the Run section.

@MainActor
extension Engine {
    static func runAgent(args: [String]) async {
        let flags = CaseRunFlags(args: args)
        let reporter = AgentReporter()
        func fail(_ message: String) async -> Never {
            reporter.send(["t": "agent-error", "message": message])
            print("✗ \(message)")
            exit(1)
        }

        let projectRoot = WorkingDirectory.url
        guard let repoArgument = flags.value("repo"), !repoArgument.isEmpty else {
            await fail("No repository is set. Choose a local repository in Settings (or pass --repo=<folder>).")
        }
        let repoURL = URL(fileURLWithPath: (repoArgument as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            await fail("The repository folder does not exist: \(repoArgument)")
        }

        let provider = flags.value("provider") ?? "deepseek"
        let strong: any ToolCallingLLM, fast: any ToolCallingLLM
        if provider == "gemini" {
            guard let config = try? Configuration.load() else { await fail("GEMINI_API_KEY was not found in the environment or .env.") }
            strong = GeminiToolCaller(apiKey: config.apiKey, model: flags.value("model") ?? config.model)
            fast = GeminiToolCaller(apiKey: config.apiKey, model: config.model)
        } else {
            guard let key = resolveDeepSeekAPIKey() else { await fail("DEEPSEEK_API_KEY was not found in the environment or .env.") }
            let strongModel = flags.value("model") ?? "deepseek-reasoner"
            strong = DeepSeekToolCaller(apiKey: key, model: strongModel, maxTokens: strongModel == "deepseek-chat" ? 8192 : 32000)
            fast = DeepSeekToolCaller(apiKey: key, model: "deepseek-chat")
        }

        // The team's setup; a missing or unusable flow means the full team.
        let flow = flags.value("flow").flatMap(AgentFlow.decode) ?? .full
        let sandbox = RepoSandbox(root: repoURL)
        let inbox = AgentInbox()
        inbox.start()
        let team = AgentTeam(projectRoot: projectRoot, sandbox: sandbox, strong: strong, fast: fast, inbox: inbox, reporter: reporter,
                             defaultBundleID: SimulatorTargetConfiguration.current.bundleID, flow: flow)
        reporter.send(["t": "agent-ready", "repo": sandbox.root.path, "provider": provider, "model": strong.modelName, "flow": flow.name])

        var history: [(user: String, answer: String)] = []
        var pending: String? = flags.value("scenario")
        while true {
            let text: String
            if let first = pending { text = first; pending = nil }
            else if let input = await inbox.next(kind: "user") { text = input.text }
            else { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // The app sends what it remembers right before the first message of a new agent process: earlier turns and facts.
            if let memory = inbox.takeQueued(kind: "memory"), let data = memory.text.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                history = ((object["turns"] as? [[String: String]]) ?? []).map { (user: $0["user"] ?? "", answer: $0["answer"] ?? "") }
                await team.state.restore(facts: (object["facts"] as? [String: String]) ?? [:])
            }

            var task = "Repository (read-only): \(sandbox.root.path)\n"
            if !history.isEmpty {
                task += "Earlier in this conversation:\n" + history.suffix(6).map { "Person: \($0.user.prefix(1500))\nTeam: \($0.answer.prefix(2500))" }.joined(separator: "\n") + "\n\n"
            }
            task += await team.state.factsBlock()
            task += "Person says: \(text)"
            let turnStarted = Date()
            do {
                let answer = try await team.orchestrator.run(task: task, state: team.state, reporter: reporter)
                let verdict = answer.range(of: #"VERDICT:\s*(PASS|FAIL|INCOMPLETE|NONE)"#, options: .regularExpression)
                    .map { String(answer[$0]).replacingOccurrences(of: "VERDICT:", with: "").trimmingCharacters(in: .whitespaces) } ?? "NONE"
                reporter.send(["t": "agent-final", "verdict": verdict, "caseKey": await team.state.caseKey ?? "", "seconds": Int(Date().timeIntervalSince(turnStarted)),
                               "calls": await team.state.llmCalls, "answer": String(answer.prefix(4000)), "facts": await team.state.facts(), "input": await team.state.inputTokens, "output": await team.state.outputTokens, "cached": await team.state.cachedTokens])
                history.append((text, answer))
            } catch {
                reporter.send(["t": "agent-error", "message": error.localizedDescription])
            }
        }
    }
}
