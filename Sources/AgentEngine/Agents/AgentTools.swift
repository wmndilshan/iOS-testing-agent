import Foundation
import AgentCore
import AgentInfrastructure
import CodeIntelligence
import TestCaseSources

/// The tools of each agent. Repository tools only read; the one writing tool saves a test case into this project's `TestCases` folder.
enum AgentTools {
    static func repository(sandbox: RepoSandbox, knowledge: RepoKnowledge) -> [AgentTool] {
        let path = ["path": Schema.string("Repository-relative path")]
        return [
            AgentTool(name: "repo_overview", description: "START HERE. One call that maps the repository from the AST index: bundle identifiers, folders, @main entry points, navigation enums (tabs/sections), screens/views, state models. Costs one cheap call instead of many searches.") { _ in
                RepoInsights.overview(knowledge)
            },
            AgentTool(name: "ui_strings", description: "The words a user sees or a test can target in a Swift file or folder: titles, buttons, fields, toggles, accessibility labels and identifiers, with line numbers. Use it on a screen's file instead of reading the file.",
                      properties: path, required: ["path"]) { args in RepoInsights.uiStrings(knowledge, path: try Self.required(args, "path")) },
            AgentTool(name: "file_outline", description: "Declarations of one Swift file (types, methods, properties) with line numbers and signatures, from the AST index. Cheaper than read_file.",
                      properties: path, required: ["path"]) { args in
                let relative = try Self.required(args, "path")
                _ = try sandbox.resolve(relative)
                return RepoInsights.outline(knowledge, path: relative)
            },
            AgentTool(name: "describe_symbol", description: "A type or function by exact name: signature, location, conformances, members, and the files that use it.",
                      properties: ["name": Schema.string("Exact declaration name, for example SimulatorView")], required: ["name"]) { args in
                RepoInsights.describe(knowledge, name: try Self.required(args, "name"))
            },
            AgentTool(name: "code_index", description: "Find declarations whose name contains a text (AST index): kind, name, file:line, signature.",
                      properties: ["query": Schema.string("Part of a declaration name"), "kind": Schema.string("Optional: struct, class, enum, actor, protocol, method, function, property, enumCase"),
                                   "limit": Schema.integer("Max results, default 25")], required: ["query"]) { args in
                let (index, _) = knowledge.index()
                let query = try Self.required(args, "query").lowercased()
                let kind = args.string("kind").flatMap { DeclarationKind(rawValue: $0) }
                let matches = index.declarations.values.filter { $0.name.lowercased().contains(query) && (kind == nil || $0.kind == kind) }
                    .sorted { ($0.span.file, $0.span.line) < ($1.span.file, $1.span.line) }
                let limit = min(args.int("limit") ?? 25, 60)
                if matches.isEmpty { return "No declaration name contains '\(query)'." }
                return matches.prefix(limit).map { "\($0.kind.rawValue) \($0.name)  \($0.span.file):\($0.span.line)  \($0.signature.prefix(110))" }.joined(separator: "\n")
                    + (matches.count > limit ? "\n…\(matches.count - limit) more" : "")
            },
            AgentTool(name: "search_text", description: "Case-insensitive text search over the repository's source, project and plist files (kept in memory). Returns path:line: text, at most 4 per file.",
                      properties: ["query": Schema.string("Text to find"), "path": Schema.string("Folder to search in, default the whole repository")], required: ["query"]) { args in
                let folder = args.string("path") ?? "."
                _ = try sandbox.resolve(folder)
                let hits = knowledge.search(try Self.required(args, "query"), under: folder)
                return hits.isEmpty ? "No matches." : hits.joined(separator: "\n")
            },
            AgentTool(name: "read_file", description: "Read a text file. Large files return their first 200 lines; pass from/to (1-based) for another window. Prefer file_outline and ui_strings first.",
                      properties: ["path": Schema.string("File, relative to the repository root"), "from": Schema.integer("First line"), "to": Schema.integer("Last line")],
                      required: ["path"]) { args in
                let relative = try Self.required(args, "path")
                if args.int("from") != nil || args.int("to") != nil { return try sandbox.read(relative, from: args.int("from"), to: args.int("to")) }
                let text = try sandbox.read(relative)
                let lines = text.components(separatedBy: "\n")
                return lines.count > 200 ? lines.prefix(200).joined(separator: "\n") + "\n…(\(lines.count - 200) more lines; use from/to or file_outline)" : text
            },
            AgentTool(name: "list_dir", description: "List a folder (relative path, '.' for the root). Folders end with '/'.", properties: path, required: ["path"]) { args in
                try sandbox.list(args.string("path") ?? ".").prefix(80).joined(separator: "\n")
            },
            AgentTool(name: "plan_tests", description: "CodeIntelligence test planning for specific files: risks and the behaviors a test should cover. Slow (builds the symbol graph); use only when behavior is unclear.",
                      properties: ["files": Schema.array(of: .dictionary(["type": .string("string")]), "Repository-relative Swift file paths")], required: ["files"], parallelSafe: false) { args in
                guard case .array(let values)? = args["files"] else { throw RepoSandbox.Refused(reason: "files is required") }
                let files = try values.compactMap(\.stringValue).prefix(6).map { path -> String in _ = try sandbox.resolve(path); return path }
                guard !files.isEmpty else { throw RepoSandbox.Refused(reason: "give at least one file") }
                var configuration = TestPlanningConfiguration()
                configuration.cacheURL = knowledge.cacheURL
                let plan = try TestPlanningPipeline(root: sandbox.root, configuration: configuration).run(source: ExplicitFilesChangeSource(root: sandbox.root, paths: Array(files)))
                var lines = ["Plan status: \(plan.status.rawValue); overall risk \(plan.overallRisk.level.rawValue); \(plan.specifications.count) specification(s)."]
                for spec in plan.specifications.prefix(8) {
                    lines.append("- \(spec.title) [\(spec.category.rawValue), risk \(spec.risk.rawValue)]: \(spec.purpose.prefix(160))")
                    for expectation in spec.expectedOutcome.prefix(2) { lines.append("    expect: \(expectation.text.prefix(140))") }
                }
                return lines.joined(separator: "\n")
            },
        ]
    }

    static func required(_ args: [String: AnyCodableValue], _ key: String) throws -> String {
        guard let value = args.string(key), !value.isEmpty else { throw RepoSandbox.Refused(reason: "\(key) is required") }
        return value
    }

    static func validKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespaces).uppercased()
        return key.range(of: #"^[A-Z0-9][A-Z0-9_-]{1,40}$"#, options: .regularExpression) != nil ? key : nil
    }

    static func caseURL(projectRoot: URL, key: String) -> URL { projectRoot.appendingPathComponent("TestCases/\(key).json") }

    static func author(projectRoot: URL, state: AgentState, reporter: AgentReporter) -> [AgentTool] {
        let stepSchema = Schema.object(["action": Schema.string("One thing to do on screen, in plain words (tap, type, scroll, open)"),
                                        "data": Schema.string("Text to type or choose, empty when none"),
                                        "expected": Schema.string("What must be visible after the step")], required: ["action", "expected"])
        return [
            AgentTool(name: "list_cases", description: "List the existing test cases in the TestCases folder.") { _ in
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: projectRoot.appendingPathComponent("TestCases").path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
                return names.isEmpty ? "No test cases yet." : names.joined(separator: "\n")
            },
            AgentTool(name: "read_case", description: "Read an existing test case file by key, as a format example or to check a case.",
                      properties: ["key": Schema.string("Case key, for example SAFARI-1")], required: ["key"]) { args in
                guard let key = args.string("key").flatMap(validKey), let text = try? String(contentsOf: caseURL(projectRoot: projectRoot, key: key), encoding: .utf8) else {
                    throw RepoSandbox.Refused(reason: "No such case. Use list_cases.")
                }
                return text
            },
            AgentTool(name: "write_test_case", description: "Save a test case for the simulator runner as TestCases/<key>.json. Steps are numbered in order and must be plain UI actions. Refuses to replace a case a person wrote.",
                      properties: ["key": Schema.string("Short id, letters digits '-' '_', for example AGENT-LOGIN-1"), "title": Schema.string("One-line title"),
                                   "bundle_id": Schema.string("Bundle id of the app under test, for example com.apple.mobilesafari"),
                                   "steps": Schema.array(of: stepSchema, "Ordered steps")],
                      required: ["key", "title", "bundle_id", "steps"], parallelSafe: false) { args in
                var steps: [TestCaseStep] = []
                guard case .array(let rawSteps)? = args["steps"] else { throw RepoSandbox.Refused(reason: TestCaseStoreError.stepCount.localizedDescription) }
                for raw in rawSteps {
                    guard case .dictionary(let fields) = raw else { throw RepoSandbox.Refused(reason: "each step must be an object with action and expected.") }
                    steps.append(TestCaseStep(number: steps.count + 1, action: fields.string("action") ?? "", data: fields.string("data") ?? "", expected: fields.string("expected") ?? ""))
                }
                let saved: TestCase
                do {
                    saved = try FileTestCaseStore(directory: projectRoot.appendingPathComponent("TestCases"))
                        .save(key: args.string("key") ?? "", title: args.string("title") ?? "", source: "agent", steps: steps, replacing: .agentCases)
                } catch let error as TestCaseStoreError {
                    throw RepoSandbox.Refused(reason: error.localizedDescription)
                }
                let (key, title) = (saved.key, saved.title)
                await state.setCase(key: key, bundleID: args.string("bundle_id"))
                // The person sees the case itself, not just the agent's description of it.
                reporter.send(["t": "agent-case", "key": key, "title": title, "bundleID": args.string("bundle_id") ?? "",
                               "steps": saved.steps.map { ["number": $0.number, "action": $0.action, "data": $0.data, "expected": $0.expected] as [String: Any] }])
                return "Saved TestCases/\(key).json with \(saved.steps.count) steps for app \(args.string("bundle_id") ?? "(none)")."
            },
        ]
    }

    /// Running a case needs the person's approval and is done by the app, which shows it live in the Run section.
    static func runner(projectRoot: URL, state: AgentState, inbox: AgentInbox, reporter: AgentReporter) -> [AgentTool] {
        [
            AgentTool(name: "run_case", description: "Run a saved test case on the iOS simulator. The person is asked to approve first. Returns the outcome and each step's result. After a run stopped at a failed step, pass from_step to continue from that step instead of starting over.",
                      properties: ["key": Schema.string("Case key written by the case author"), "bundle_id": Schema.string("Bundle id of the app under test"),
                                   "from_step": Schema.integer("Optional: continue from this step (the earlier steps keep their results). Use after a run stopped at a failed step.")],
                      required: ["key"], parallelSafe: false) { args in
                guard let key = args.string("key").flatMap(validKey), FileManager.default.fileExists(atPath: caseURL(projectRoot: projectRoot, key: key).path) else {
                    throw RepoSandbox.Refused(reason: "That case is not saved. Ask the case author to write it first.")
                }
                let bundle: String
                if let given = args.string("bundle_id"), !given.isEmpty { bundle = given } else { bundle = await state.bundleID ?? "" }
                let fromStep = max(1, args.int("from_step") ?? 1)
                let promptID = "run-\(key)-\(UUID().uuidString.prefix(6))"
                reporter.send(["t": "prompt", "id": promptID, "kind": "approval", "caseKey": key, "title": "Run \(key) on the simulator?",
                               "message": "The agents want to run test case \(key)\(fromStep > 1 ? " from step \(fromStep)" : "")\(bundle.isEmpty ? "" : " against \(bundle)") on the booted simulator. It will tap and type in the app.", "secure": false])
                // An unanswered question must not leave the team waiting for ever.
                let answer = await inbox.next(kind: "answer", id: promptID, timeout: 600)
                reporter.send(["t": "prompt-done", "id": promptID])
                guard let answer else { return "The approval request timed out after 10 minutes. Nothing was executed." }
                guard answer.text == "approve" else { return "The person did not approve the run. Nothing was executed." }
                reporter.send(["t": "agent-run-request", "key": key, "bundleID": bundle, "fromStep": fromStep])
                guard let result = await inbox.next(kind: "run-result") else { throw RepoSandbox.Refused(reason: "The app closed before the run finished.") }
                await state.setLastRun(result.text)
                return result.text
            },
            AgentTool(name: "get_last_run_result", description: "The result of the most recent run in this conversation.") { _ in
                await state.lastRun ?? "No run has happened in this conversation."
            },
        ]
    }

    static func validator(projectRoot: URL, state: AgentState) -> [AgentTool] {
        [
            AgentTool(name: "get_last_run_result", description: "The outcome and per-step results of the most recent simulator run.") { _ in
                await state.lastRun ?? "No run has happened in this conversation."
            },
            AgentTool(name: "read_case", description: "Read a saved test case by key to compare its expectations with the run.",
                      properties: ["key": Schema.string("Case key")], required: ["key"]) { args in
                guard let key = args.string("key").flatMap(validKey), let text = try? String(contentsOf: caseURL(projectRoot: projectRoot, key: key), encoding: .utf8) else {
                    throw RepoSandbox.Refused(reason: "No such case.")
                }
                return text
            },
        ]
    }
}
