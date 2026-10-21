import Foundation
import AgentCore
import AgentInfrastructure
import TestCaseSources

/// Test cases and their runs: list, read and write cases, run one, and read past reports. Runs launch the command line tool as a process (the engine
/// owns the run lock and the device), so the gateway never executes steps itself.
enum CaseGatewayTools {
    static func tools(_ services: GatewayServices) -> [GatewayTool] {
        let store = FileTestCaseStore(directory: services.casesDirectory)
        let library = CaseLibrary(store: store, cache: FileTestCaseSource(directory: services.cachedCasesDirectory), cacheDirectory: services.cachedCasesDirectory)
        return [listCases(library), readCase(library), writeCase(store), GenerateCasesTool.tool(services, store), runCase(services, store), listRuns(services), getReport(services)]
    }

    // MARK: Cases

    private static func listCases(_ library: CaseLibrary) -> GatewayTool {
        GatewayTool(name: "list_cases", description: "The test cases of this project: those in TestCases/ and those fetched earlier from AIO (key, title, step count).", properties: [:], readOnly: true) { _, _ in
            let keys = library.keys()
            guard !keys.isEmpty else { return .text("There are no test cases yet. Write one with write_case.") }
            return .text(await keys.asyncMap { key in
                let value = try? await library.load(key: key)
                return "\(key) — \(value?.title ?? "(unreadable)") (\(value?.steps.count ?? 0) steps)"
            }.joined(separator: "\n"))
        }
    }

    private static func readCase(_ library: CaseLibrary) -> GatewayTool {
        GatewayTool(name: "read_case", description: "One test case with its steps: action, test data and expected result.", properties: ["key": Schema.string("The case key, for example SAFARI-1")],
                    required: ["key"], readOnly: true) { args, _ in
            guard let key = args.string("key"), let normalized = FileTestCaseStore.normalizedKey(key) else { return .error("key must look like SAFARI-1 (letters, digits, - and _).") }
            do {
                let value = try await library.load(key: normalized)
                let steps = value.steps.map { "\($0.number). \($0.action)" + ($0.data.isEmpty ? "" : " [data: \($0.data)]") + " → expect: \($0.expected)" }
                return .text("\(value.key) — \(value.title) (source: \(value.source))\n" + steps.joined(separator: "\n"))
            } catch { return .error(error.localizedDescription) }
        }
    }

    private static func writeCase(_ store: FileTestCaseStore) -> GatewayTool {
        let step = Schema.object(["action": Schema.string("What to do, in plain words"), "data": Schema.string("Test data to type or choose, if any"),
                                  "expected": Schema.string("What the screen shows when the step worked; quote exact labels")], required: ["action", "expected"])
        return GatewayTool(name: "write_case", description: "Create a test case in TestCases/. A key that already exists is refused unless replace=true and the case was written by an agent. Passwords are never written here: use the placeholder [CREDENTIALS].",
                           properties: ["key": Schema.string("New case key, for example LOGIN-2"), "title": Schema.string("One line saying what the case checks"),
                                        "steps": Schema.array(of: step, "1 to 25 steps, in order"), "replace": Schema.boolean("Replace an existing agent-written case")],
                           required: ["key", "title", "steps"], readOnly: false) { args, _ in
            guard let key = args.string("key"), let title = args.string("title"), case .array(let raw)? = args["steps"] else { return .error("key, title and steps are required.") }
            var steps: [TestCaseStep] = []
            for item in raw {
                guard case .dictionary(let fields) = item, let action = fields.string("action") else { return .error("Every step needs an action and an expected result.") }
                steps.append(TestCaseStep(number: steps.count + 1, action: action, data: fields.string("data") ?? "", expected: fields.string("expected") ?? ""))
            }
            do {
                let saved = try store.save(key: key, title: title, source: "agent", steps: steps, replacing: args.bool("replace") == true ? .agentCases : .nothing)
                return .text("Saved \(saved.key) (\(saved.steps.count) steps) in TestCases/\(saved.key).json. Run it with run_case.")
            } catch { return .error(error.localizedDescription) }
        }
    }

    // MARK: Runs

    private static func runCase(_ services: GatewayServices, _ store: FileTestCaseStore) -> GatewayTool {
        GatewayTool(name: "run_case", description: "Run a test case on the booted simulator and wait for the result (minutes). The runner plans and judges with its own model, so DEEPSEEK_API_KEY (or Gemini) must be set where the server runs; without a key use the device tools directly. The password comes from TEST_USER_PASSWORD in the server's environment, never from here. A destructive step is refused unless allow_destructive=true. Returns the outcome and each step's result.",
                    properties: ["key": Schema.string("Case key"), "bundle_id": Schema.string("Bundle id of the app under test; default the case's own app"),
                                 "start_step": Schema.integer("First step to run"), "end_step": Schema.integer("Last step to run"),
                                 "username": Schema.string("Username for the login step; default TEST_USER_USERNAME"),
                                 "allow_destructive": Schema.boolean("Allow steps that delete or log out; only after the person agreed"),
                                 "guidance": Schema.string("Plain-words instructions for the run, saved for this case until cleared. For a name that already exists: \"use Test2 instead of Test1\". Other words become notes for the planner and judge"),
                                 "clear_guidance": Schema.boolean("Forget the guidance saved for this case before running")],
                    required: ["key"], readOnly: false) { args, progress in
            guard let launcher = services.launcher else { return .error("The test runner is not available.") }
            guard let key = args.string("key"), let normalized = FileTestCaseStore.normalizedKey(key) else { return .error("key must look like SAFARI-1.") }
            var arguments = ["--run-case=\(normalized)", "--mode=LIVE_AUTONOMOUS_AFTER_LOGIN", "--events"]
            if let bundle = args.string("bundle_id") { arguments.append("--bundle-id=\(bundle)") }
            if let start = args.int("start_step") { arguments.append("--start-step=\(start)") }
            if let end = args.int("end_step") { arguments.append("--end-step=\(end)") }
            let username = args.string("username") ?? services.environment["TEST_USER_USERNAME"]
            if let username, !username.isEmpty { arguments.append("--username=\(username)") }
            if args.bool("allow_destructive") == true { arguments.append("--allow-destructive") }
            if args.bool("clear_guidance") == true { arguments.append("--clear-guidance") }
            if let guidance = args.string("guidance") {
                // One flag per sentence, on one line each: a value cannot carry a second flag or a newline into the command line.
                for sentence in guidance.replacingOccurrences(of: "\n", with: ";").split(separator: ";").prefix(8) {
                    let text = sentence.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { arguments.append("--note=\(text.prefix(300))") }
                }
            }
            return await RunMonitor(services: services, launcher: launcher).run(arguments: arguments, key: normalized, progress: progress)
        }
    }

    private static func listRuns(_ services: GatewayServices) -> GatewayTool {
        GatewayTool(name: "list_runs", description: "Recent case runs, newest first: id, case, outcome, when and how long.", properties: ["limit": Schema.integer("How many, default 10")], readOnly: true) { args, _ in
            let reports = RunReports.all(in: services.caseRunsDirectory).prefix(max(1, min(args.int("limit") ?? 10, 50)))
            guard !reports.isEmpty else { return .text("No runs yet.") }
            return .text(reports.map { "\($0.id) | \($0.report.testKey) | \($0.report.outcome) | \(RunReports.when($0.report.startedAt)) | \(RunReports.duration($0.report))" }.joined(separator: "\n"))
        }
    }

    private static func getReport(_ services: GatewayServices) -> GatewayTool {
        GatewayTool(name: "get_report", description: "One run's report: outcome and every step with its result and detail. Use the id from list_runs or run_case. format=junit returns JUnit XML for a CI system; with no run_id it covers the latest run of each case.",
                    properties: ["run_id": Schema.string("The run id; optional with format=junit"), "format": Schema.choice(["text", "junit"], "text (default) or junit")],
                    readOnly: true) { args, _ in
            let junit = args.string("format") == "junit"
            if junit, args.string("run_id") == nil {
                var seen = Set<String>()
                let latest = RunReports.all(in: services.caseRunsDirectory).filter { seen.insert($0.report.testKey).inserted }
                return .text(JUnitReport.xml(latest.map { ($0.id, $0.report) }))
            }
            guard let id = args.string("run_id"), !id.contains("/"), !id.contains("..") else { return .error("run_id must be an id from list_runs.") }
            guard let entry = RunReports.all(in: services.caseRunsDirectory).first(where: { $0.id == id }) else { return .error("No run has the id “\(id)”. Use list_runs.") }
            return .text(junit ? JUnitReport.xml([(entry.id, entry.report)]) : RunReports.summary(entry))
        }
    }
}

/// The cases a run can use: the project's own (`TestCases/`) and those fetched earlier from AIO and cached (`Scripts/AIO/generated`). Own cases win, as in the runner.
struct CaseLibrary: Sendable {
    let store: FileTestCaseStore
    let cache: FileTestCaseSource
    let cacheDirectory: URL

    func keys() -> [String] {
        let cached = ((try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [])
            .filter { ($0.hasSuffix(".md") || $0.hasSuffix(".json")) && !$0.hasSuffix("_detail.json") }
            .map { ($0 as NSString).deletingPathExtension }
        return Array(Set(store.keys() + cached)).sorted()
    }

    func load(key: String) async throws -> TestCase {
        if let own = try? store.load(key: key) { return own }
        return try await cache.testCase(key: key)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for item in self { out.append(await transform(item)) }
        return out
    }
}

/// Reads the run reports the runner saves under `.runs/cases`.
enum RunReports {
    struct Entry { let id: String; let report: CaseRunReport; let url: URL }

    static func all(in directory: URL) -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let report = try? decoder.decode(CaseRunReport.self, from: data) else { return nil }
            return Entry(id: url.deletingPathExtension().lastPathComponent, report: report, url: url)
        }.sorted { ($0.report.startedAt, $0.id) > ($1.report.startedAt, $1.id) }
    }

    static func when(_ date: Date) -> String { date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)) }

    static func duration(_ report: CaseRunReport) -> String {
        report.finishedAt.map { "\(Int($0.timeIntervalSince(report.startedAt))) s" } ?? "running"
    }

    static func summary(_ entry: Entry) -> String {
        let report = entry.report
        var lines = ["\(entry.id): \(report.testKey) — \(report.title)", "Outcome: \(report.outcome) (\(duration(report)))", "Report file: \(entry.url.path)"]
        for step in report.steps {
            lines.append("step \(step.sourceStepNumber) [\(step.status.rawValue)] \(step.intent)" + (step.detail.isEmpty ? "" : " — \(step.detail.prefix(240))"))
        }
        return lines.joined(separator: "\n")
    }
}
