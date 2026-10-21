import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

private func makeFolder() -> URL {
    let url = ProductFixtures.tempDir()
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class FakeAgentProcess: CaseRunHandle, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var sentLines: [String] = []
    var sent: [String] { lock.withLock { sentLines } }
    init() {
        var captured: AsyncStream<String>.Continuation!
        lines = AsyncStream { captured = $0 }
        continuation = captured
    }
    func send(_ line: String) { lock.withLock { sentLines.append(line) } }
    func emitLine(_ line: String) { continuation.yield(line) }
    func terminate() { continuation.finish() }
}

private struct FakeAgentLauncher: CaseRunLaunching {
    let process: FakeAgentProcess
    func launch(arguments: [String]) throws -> any CaseRunHandle { process }
}

@MainActor
@Suite("Agent chat state")
struct AgentChatStateTests {
    private func makeState(repository: String? = nil) -> (AgentChatState, FakeAgentProcess, UserDefaults) {
        let defaults = UserDefaults(suiteName: "agent-chat-tests-\(UUID().uuidString)")!
        if let repository { defaults.set(repository, forKey: AgentChatState.defaultsKey) }
        let process = FakeAgentProcess()
        return (AgentChatState(projectRoot: makeFolder(), launcher: FakeAgentLauncher(process: process), defaults: defaults), process, defaults)
    }

    private func event(_ fields: [String: Any]) -> String {
        "@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test("The repository setting is saved, validated and read back")
    func repositorySetting() {
        let (state, _, defaults) = makeState()
        #expect(state.repositoryStatus == .notSet)
        let folder = makeFolder()
        state.setRepositoryPath(folder.path)
        #expect(defaults.string(forKey: AgentChatState.defaultsKey) == folder.path)
        #expect(state.repositoryStatus == .ready(swiftProject: false))
        state.setRepositoryPath("/no/such/folder")
        #expect(state.repositoryStatus == .missing)
        #expect(AgentChatState(projectRoot: folder, launcher: FakeAgentLauncher(process: FakeAgentProcess()), defaults: defaults).repositoryPath == "/no/such/folder")
    }

    @Test("Sending without a usable repository adds an error and starts nothing")
    func needsRepository() {
        let (state, process, _) = makeState()
        state.send("test login")
        #expect(state.messages.last?.kind == .error)
        #expect(state.isConversationActive == false)
        #expect(process.sent.isEmpty)
    }

    @Test("A message is written to the agent as a JSON line, and its streamed events build the conversation")
    func conversation() throws {
        let (state, process, _) = makeState(repository: makeFolder().path)
        state.send("test login")
        let line = try #require(process.sent.first)
        #expect((try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])?["text"] == "test login")
        #expect(state.isBusy)

        state.consume(event(["t": "agent-start", "agent": "Orchestrator", "role": "Plans"]))
        state.consume(event(["t": "agent-think", "agent": "Orchestrator", "delta": "I should "]))
        state.consume(event(["t": "agent-think", "agent": "Orchestrator", "delta": "read the repo"]))
        state.consume(event(["t": "agent-turn-end", "agent": "Orchestrator"]))
        state.consume(event(["t": "agent-tool", "agent": "Orchestrator", "id": "c1", "name": "delegate_repo_analyst", "args": "{}"]))
        state.consume(event(["t": "agent-handoff", "from": "Orchestrator", "to": "RepoAnalyst", "task": "find login"]))
        state.consume(event(["t": "agent-tool-result", "agent": "Orchestrator", "id": "c1", "ok": true, "summary": "found"]))

        let kinds = state.messages.map(\.kind)
        #expect(kinds == [.user, .thinking, .tool, .handoff])
        #expect(state.messages[1].text == "I should read the repo")
        #expect(state.messages[1].isOpen == false)
        #expect(state.messages[2].result == "found")
        #expect(state.agents.first { $0.id == "RepoAnalyst" }?.phase == .working)

        state.consume(event(["t": "agent-final", "verdict": "PASS", "caseKey": "AGENT-1"]))
        #expect(state.isBusy == false)
        #expect(state.messages.last?.kind == .verdict)
        #expect(state.lastCaseKey == "AGENT-1")
    }

    @Test("Token usage and tool timings from the agent are shown")
    func usageAndTimings() {
        let (state, _, _) = makeState(repository: makeFolder().path)
        state.send("hi")
        state.consume(event(["t": "agent-tool", "agent": "Orchestrator", "id": "c1", "name": "x", "args": "{}"]))
        state.consume(event(["t": "agent-tool-result", "id": "c1", "ok": true, "summary": "r", "ms": 120]))
        state.consume(event(["t": "agent-usage", "agent": "Orchestrator", "input": 1000, "output": 100, "cached": 500, "ms": 5, "totalInput": 1000, "totalOutput": 100, "totalCached": 500]))
        #expect(state.messages.last?.milliseconds == 120)
        #expect(state.usage.summary == "1.0k in · 100 out · 50% cached")
        state.consume(event(["t": "agent-final", "verdict": "NONE", "caseKey": "", "seconds": 9, "calls": 4, "input": 2000, "output": 300, "cached": 1500]))
        #expect(state.usage.seconds == 9 && state.usage.summary == "2.0k in · 300 out · 75% cached")
    }

    @Test("An approval prompt is shown and the answer goes back with its id")
    func approval() throws {
        let (state, process, _) = makeState(repository: makeFolder().path)
        state.send("run it")
        state.consume(event(["t": "prompt", "id": "run-1", "kind": "approval", "title": "Run?", "message": "m"]))
        #expect(state.prompt?.id == "run-1")
        state.answer("approve")
        #expect(state.prompt == nil)
        let sent = try #require(process.sent.last)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: String])
        #expect(object["t"] == "answer" && object["id"] == "run-1" && object["text"] == "approve")
    }

    @Test("Changing the repository during a conversation ends it")
    func repositoryChangeEndsConversation() {
        let (state, _, _) = makeState(repository: makeFolder().path)
        state.send("hi")
        #expect(state.isConversationActive)
        state.setRepositoryPath(makeFolder().path)
        #expect(state.isConversationActive == false)
        #expect(state.isBusy == false)
    }
}


@MainActor
@Suite("Agent timeline and streaming load")
struct AgentTimelineTests {
    private func event(_ fields: [String: Any]) -> String {
        "@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    private func state() -> AgentChatState {
        let defaults = UserDefaults(suiteName: "agent-timeline-\(UUID().uuidString)")!
        defaults.set(makeFolder().path, forKey: AgentChatState.defaultsKey)
        return AgentChatState(projectRoot: makeFolder(), launcher: FakeAgentLauncher(process: FakeAgentProcess()), defaults: defaults)
    }

    @Test("A specialist's work becomes one section; the orchestrator's delegate call is hidden")
    func sections() {
        let chat = state()
        chat.send("test it")
        chat.consume(event(["t": "agent-think", "agent": "Orchestrator", "delta": "plan"]))
        chat.consume(event(["t": "agent-turn-end", "agent": "Orchestrator"]))
        chat.consume(event(["t": "agent-tool", "agent": "Orchestrator", "id": "d1", "name": "delegate_repo_analyst", "args": "{}"]))
        chat.consume(event(["t": "agent-handoff", "from": "Orchestrator", "to": "RepoAnalyst", "task": "find login"]))
        chat.consume(event(["t": "agent-tool", "agent": "RepoAnalyst", "id": "t1", "name": "repo_overview", "args": "{}"]))
        chat.consume(event(["t": "agent-tool-result", "id": "t1", "ok": true, "summary": "ok", "ms": 5]))
        chat.consume(event(["t": "agent-text", "agent": "RepoAnalyst", "delta": "report"]))
        chat.consume(event(["t": "agent-turn-end", "agent": "RepoAnalyst"]))
        chat.consume(event(["t": "agent-tool-result", "id": "d1", "ok": true, "summary": "report", "ms": 900]))
        chat.consume(event(["t": "agent-text", "agent": "Orchestrator", "delta": "# Done"]))

        let items = AgentTimeline.build(chat.messages, isBusy: false)
        guard items.count == 4, case .section(let section) = items[2] else { Issue.record("unexpected timeline \(items.count)"); return }
        #expect(section.agent == "RepoAnalyst" && section.task == "find login")
        #expect(section.toolCount == 1 && section.items.map(\.kind) == [.tool, .text])
        #expect(!section.isActive)
        if case .message(let last) = items[3] { #expect(last.kind == .text && last.agent == "Orchestrator") } else { Issue.record("answer missing") }
        #expect(AgentTimeline.build(chat.messages, isBusy: true).count == 4)
    }

    @Test("The last section stays active while the run is busy")
    func activeSection() {
        let chat = state()
        chat.send("go")
        chat.consume(event(["t": "agent-handoff", "from": "Orchestrator", "to": "CaseAuthor", "task": "write"]))
        chat.consume(event(["t": "agent-think", "agent": "CaseAuthor", "delta": "hmm"]))
        guard case .section(let section)? = AgentTimeline.build(chat.messages, isBusy: true).last else { Issue.record("no section"); return }
        #expect(section.isActive && section.endedAt == nil)
    }

    @Test("Thousands of streamed pieces change the published revision only a handful of times")
    func throttle() async {
        let chat = state()
        chat.send("go")
        let before = chat.transcript.revision
        for index in 0..<4000 { chat.consume(event(["t": "agent-text", "agent": "Orchestrator", "delta": "w\(index) "])) }
        #expect(chat.messages.last?.text.hasPrefix("w0 w1 ") == true)
        #expect(chat.transcript.revision - before <= 3, "published \(chat.transcript.revision - before) times for one burst")
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(chat.transcript.revision - before <= 5)
    }
}

@Suite("Markdown blocks")
struct MarkdownParserTests {
    @Test("Headings, lists, code fences, quotes, tables and paragraphs are told apart")
    func blocks() {
        let text = """
        # Title
        Some **bold** text
        still the same paragraph

        - one
          - nested
        1. first

        > quoted

        ```swift
        let x = 1
        ```

        | A | B |
        |---|---|
        | 1 | 2 |
        ---
        """
        let blocks = MarkdownParser.parse(text)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\nstill the same paragraph"),
            .listItem(indent: 0, marker: "•", text: "one"),
            .listItem(indent: 1, marker: "•", text: "nested"),
            .listItem(indent: 0, marker: "1.", text: "first"),
            .quote("quoted"),
            .code(language: "swift", text: "let x = 1"),
            .table(header: ["A", "B"], rows: [["1", "2"]]),
            .rule,
        ])
    }

    @Test("An unfinished code fence while streaming renders as code to the end")
    func unclosedFence() {
        #expect(MarkdownParser.parse("```\nlet a = 1\nlet b") == [.code(language: "", text: "let a = 1\nlet b")])
    }
}


private final class RecordingLauncher: CaseRunLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var launched: [FakeAgentProcess] = []
    private var argumentLists: [[String]] = []
    var processes: [FakeAgentProcess] { lock.withLock { launched } }
    var arguments: [[String]] { lock.withLock { argumentLists } }
    func launch(arguments: [String]) throws -> any CaseRunHandle {
        let process = FakeAgentProcess()
        lock.withLock { launched.append(process); argumentLists.append(arguments) }
        return process
    }
}

@MainActor
@Suite("Agent conversation memory")
struct AgentMemoryTests {
    private func event(_ fields: [String: Any]) -> String {
        "@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    private func make(defaults: UserDefaults, launcher: RecordingLauncher, root: URL = makeFolder()) -> AgentChatState {
        AgentChatState(projectRoot: root, launcher: launcher, defaults: defaults)
    }

    private func defaults(repository: String = makeFolder().path) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "agent-memory-\(UUID().uuidString)")!
        defaults.set(repository, forKey: AgentChatState.defaultsKey)
        return defaults
    }

    private func finishTurn(_ chat: AgentChatState, answer: String, caseKey: String = "CASE-1") {
        chat.consume(event(["t": "agent-memory", "facts": ["caseKey": caseKey, "report.RepoAnalyst": "login is at LoginView"]]))
        chat.consume(event(["t": "agent-final", "verdict": "NONE", "caseKey": caseKey, "answer": answer, "facts": ["caseKey": caseKey, "bundleID": "com.apple.mobilesafari"],
                            "seconds": 3, "calls": 2, "input": 10, "output": 5, "cached": 0]))
    }

    private func memoryLine(_ process: FakeAgentProcess) throws -> [String: Any] {
        var found: [String: Any]?
        for line in process.sent {
            if let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["t"] as? String == "memory" { found = object; break }
        }
        let line = try #require(found)
        let text = try #require(line["text"] as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("After Stop, the next message starts a new agent that is first told the earlier turns and facts")
    func restartKeepsMemory() throws {
        let launcher = RecordingLauncher()
        let chat = make(defaults: defaults(), launcher: launcher)
        chat.send("write a login test")
        finishTurn(chat, answer: "Saved CASE-1")
        chat.stop()
        chat.send("continue")

        #expect(launcher.processes.count == 2)
        #expect(launcher.processes[0].sent.contains { $0.contains("\"t\":\"memory\"") } == false, "a fresh conversation has nothing to remember")
        let memory = try memoryLine(launcher.processes[1])
        let turns = try #require(memory["turns"] as? [[String: String]])
        #expect(turns == [["user": "write a login test", "answer": "Saved CASE-1"]])
        let facts = try #require(memory["facts"] as? [String: String])
        #expect(facts["caseKey"] == "CASE-1" && facts["bundleID"] == "com.apple.mobilesafari" && facts["report.RepoAnalyst"] == "login is at LoginView")
        // The memory line comes before the message it belongs to.
        let kinds = launcher.processes[1].sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["t"] as? String }
        #expect(kinds == ["memory", "user"])
    }

    @Test("A live conversation does not resend memory: the running agent already has it")
    func liveProcessNotReminded() {
        let launcher = RecordingLauncher()
        let chat = make(defaults: defaults(), launcher: launcher)
        chat.send("one")
        finishTurn(chat, answer: "done one")
        chat.send("two")
        let kinds = launcher.processes[0].sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["t"] as? String }
        #expect(kinds == ["user", "user"])
    }

    @Test("A turn that never finished is remembered as unfinished")
    func interruptedTurn() throws {
        let launcher = RecordingLauncher()
        let chat = make(defaults: defaults(), launcher: launcher)
        chat.send("write the case")
        chat.stop()
        chat.send("continue")
        let turns = try #require(try memoryLine(launcher.processes[1])["turns"] as? [[String: String]])
        #expect(turns.first?["answer"] == "(stopped before it finished)")
    }

    @Test("Memory survives a relaunch of the app: the turns are shown again and the agents are reminded")
    func survivesRelaunch() throws {
        let store = defaults()
        let root = makeFolder()
        let first = make(defaults: store, launcher: RecordingLauncher(), root: root)
        first.send("test settings")
        first.consume(event(["t": "agent-text", "agent": "Orchestrator", "delta": "## Report\nSaved CASE-1"]))
        finishTurn(first, answer: "## Report\nSaved CASE-1")

        let launcher = RecordingLauncher()
        let second = make(defaults: store, launcher: launcher, root: root)
        #expect(second.rememberedTurns == 1)
        #expect(second.lastCaseKey == "CASE-1")
        #expect(second.messages.map(\.kind) == [.user, .text, .verdict, .notice])
        #expect(second.messages[1].text.hasPrefix("## Report"))
        second.send("continue")
        let turns = try #require(try memoryLine(launcher.processes[0])["turns"] as? [[String: String]])
        #expect(turns.count == 1 && turns[0]["user"] == "test settings")
    }

    @Test("Clearing the conversation or choosing another repository forgets everything")
    func forgetting() {
        let store = defaults()
        let chat = make(defaults: store, launcher: RecordingLauncher())
        chat.send("one")
        finishTurn(chat, answer: "a")
        chat.clear()
        #expect(chat.rememberedTurns == 0)
        #expect(make(defaults: store, launcher: RecordingLauncher()).rememberedTurns == 0)

        chat.send("two")
        finishTurn(chat, answer: "b")
        chat.setRepositoryPath(makeFolder().path)
        #expect(chat.rememberedTurns == 0)
        #expect(make(defaults: store, launcher: RecordingLauncher()).rememberedTurns == 0)
    }

    @Test("Memory for a different repository is not restored")
    func otherRepository() {
        let store = defaults()
        let chat = make(defaults: store, launcher: RecordingLauncher())
        chat.send("one")
        finishTurn(chat, answer: "a")
        store.set(makeFolder().path, forKey: AgentChatState.defaultsKey)
        #expect(make(defaults: store, launcher: RecordingLauncher()).rememberedTurns == 0)
    }
}


@MainActor
@Suite("Generated test case in the chat")
struct AgentCaseCardTests {
    private func event(_ fields: [String: Any]) -> String {
        "@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    private func chat(defaults: UserDefaults? = nil) -> (AgentChatState, UserDefaults) {
        let store = defaults ?? UserDefaults(suiteName: "agent-case-\(UUID().uuidString)")!
        if defaults == nil { store.set(makeFolder().path, forKey: AgentChatState.defaultsKey) }
        return (AgentChatState(projectRoot: makeFolder(), launcher: FakeAgentLauncher(process: FakeAgentProcess()), defaults: store), store)
    }

    private let caseEvent: [String: Any] = ["t": "agent-case", "key": "LOGIN-1", "title": "Wrong password shows an error", "bundleID": "com.apple.mobilesafari",
        "steps": [["number": 1, "action": "Launch the app", "data": "", "expected": "Login screen shown"],
                  ["number": 2, "action": "Type a wrong password", "data": "WrongPassword-1", "expected": "Masked characters"]]]

    @Test("The saved case becomes a card with its steps")
    func caseBecomesCard() throws {
        let (chat, _) = chat()
        chat.send("write a login test")
        chat.consume(event(caseEvent))
        let card = try #require(chat.messages.last)
        #expect(card.kind == .testCase)
        let info = try #require(card.caseInfo)
        #expect(info.key == "LOGIN-1" && info.bundleID == "com.apple.mobilesafari" && info.steps.count == 2)
        #expect(info.steps[1].data == "WrongPassword-1" && info.steps[1].expected == "Masked characters")
        #expect(chat.cases["LOGIN-1"] == info)
        #expect(chat.lastCaseKey == "LOGIN-1")
    }

    @Test("A case event without steps or key is ignored")
    func malformedCase() {
        let (chat, _) = chat()
        chat.send("x")
        chat.consume(event(["t": "agent-case", "key": "", "steps": []]))
        chat.consume(event(["t": "agent-case", "title": "no key"]))
        #expect(chat.messages.filter { $0.kind == .testCase }.isEmpty)
    }

    @Test("The approval prompt knows which case it is about, so the banner can show its steps")
    func promptCarriesCase() {
        let (chat, _) = chat()
        chat.send("run it")
        chat.consume(event(caseEvent))
        chat.consume(event(["t": "prompt", "id": "run-1", "kind": "approval", "caseKey": "LOGIN-1", "title": "Run LOGIN-1?", "message": "m"]))
        #expect(chat.prompt?.caseKey == "LOGIN-1")
        #expect(chat.prompt?.caseKey.flatMap { chat.cases[$0] }?.steps.count == 2)
    }

    @Test("The case is shown again after the app restarts, while its file exists")
    func caseSurvivesRelaunch() throws {
        let root = makeFolder()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("TestCases"), withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent("TestCases/LOGIN-1.json"), atomically: true, encoding: .utf8)
        let store = UserDefaults(suiteName: "agent-case-relaunch-\(UUID().uuidString)")!
        store.set(makeFolder().path, forKey: AgentChatState.defaultsKey)
        let first = AgentChatState(projectRoot: root, launcher: FakeAgentLauncher(process: FakeAgentProcess()), defaults: store)
        first.send("write a login test")
        first.consume(event(caseEvent))
        first.consume(event(["t": "agent-final", "verdict": "NONE", "caseKey": "LOGIN-1", "answer": "Saved", "facts": ["caseKey": "LOGIN-1"], "seconds": 1, "calls": 1, "input": 1, "output": 1, "cached": 0]))
        let second = AgentChatState(projectRoot: root, launcher: FakeAgentLauncher(process: FakeAgentProcess()), defaults: store)
        let card = try #require(second.messages.first { $0.kind == .testCase })
        #expect(card.caseInfo?.title == "Wrong password shows an error" && card.caseInfo?.steps.count == 2)
        #expect(second.cases["LOGIN-1"] != nil)
    }

    @Test("A case written during a specialist's section is shown right after the section, so a folded section does not hide it")
    func caseIsHoisted() {
        let (chat, _) = chat()
        chat.send("go")
        chat.consume(event(["t": "agent-handoff", "from": "Orchestrator", "to": "CaseAuthor", "task": "write"]))
        chat.consume(event(["t": "agent-tool", "agent": "CaseAuthor", "id": "w", "name": "write_test_case", "args": "{}"]))
        chat.consume(event(caseEvent))
        chat.consume(event(["t": "agent-text", "agent": "CaseAuthor", "delta": "done"]))
        chat.consume(event(["t": "agent-text", "agent": "Orchestrator", "delta": "All saved."]))
        let items = AgentTimeline.build(chat.messages, isBusy: false)
        let kinds = items.map { item -> String in
            switch item { case .section: return "section"; case .plan: return "plan"; case .message(let m): return m.kind.rawValue }
        }
        #expect(kinds == ["user", "section", "testCase", "text"])
        if case .section(let section) = items[1] { #expect(!section.items.contains { $0.kind == .testCase }) }
        // Still hoisted while the run is busy and the section is the last thing.
        let live = AgentTimeline.build(Array(chat.messages.dropLast()), isBusy: true).map { item -> String in
            switch item { case .section: return "section"; case .plan: return "plan"; case .message(let m): return m.kind.rawValue }
        }
        #expect(live == ["user", "section", "testCase"])
    }
}


@MainActor
@Suite("Run on simulator from the case card")
struct RunFromCardTests {
    private let info = AgentCaseInfo(key: "LOGIN-1", title: "Login", bundleID: "com.apple.mobilesafari",
                                     steps: [AgentCaseInfo.Step(number: 1, action: "Launch", data: "", expected: "Login shown")])

    private func setup() -> (chat: AgentChatState, workspace: WorkspaceState, runLauncher: RecordingLauncher, root: URL, run: CaseRunState) {
        let root = makeFolder()
        let defaults = UserDefaults(suiteName: "agent-run-\(UUID().uuidString)")!
        let chat = AgentChatState(projectRoot: root, launcher: RecordingLauncher(), defaults: defaults)
        let runLauncher = RecordingLauncher()
        let workspace = WorkspaceState()
        let run = CaseRunState(projectRoot: root, launcher: runLauncher)
        // The chat holds the run state weakly (the app owns it), so the test keeps it alive.
        chat.bind(workspace: workspace, caseRun: run)
        return (chat, workspace, runLauncher, root, run)
    }

    private func saveCaseFile(_ root: URL, key: String) throws {
        let folder = root.appendingPathComponent("TestCases")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent("\(key).json"), atomically: true, encoding: .utf8)
    }

    @Test("A saved case is started by key with its bundle id, and the window moves to the Run section")
    func startsSavedCase() throws {
        let (chat, workspace, runLauncher, root, run) = setup()
        defer { withExtendedLifetime(run) {} }
        try saveCaseFile(root, key: "LOGIN-1")
        workspace.show(.agent)
        chat.runNow(info)
        let arguments = try #require(runLauncher.arguments.first)
        #expect(arguments.contains("--run-case=LOGIN-1") && arguments.contains("--bundle-id=com.apple.mobilesafari"))
        #expect(workspace.section == .run)
    }

    @Test("A case whose file is gone is not started: the chat says why instead of sending the person to an empty Run screen")
    func missingFileIsReported() {
        let (chat, workspace, runLauncher, _, run) = setup()
        defer { withExtendedLifetime(run) {} }
        workspace.show(.agent)
        #expect(chat.caseFileExists("LOGIN-1") == false)
        chat.runNow(info)
        #expect(runLauncher.arguments.isEmpty)
        #expect(workspace.section == .agent)
        #expect(chat.messages.last?.kind == .notice && chat.messages.last?.text.contains("TestCases/LOGIN-1.json") == true)
    }

    @Test("A run that ends before any step shows the runner's reason on the Run screen")
    func earlyExitShowsReason() async throws {
        let root = makeFolder()
        let launcher = RecordingLauncher()
        let run = CaseRunState(projectRoot: root, launcher: launcher)
        run.start(key: "SAVED_LIST")
        let process = try #require(launcher.processes.first)
        process.emitLine("    Test Case Runner — SAVED_LIST")
        process.emitLine("✗ Loading SAVED_LIST failed: 'SAVED_LIST' is not an AIO case key (expected something like DEMO-TC-877).")
        process.terminate()
        for _ in 0..<50 where run.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(run.isRunning == false)
        #expect(run.errorMessage?.contains("is not an AIO case key") == true)
        #expect(run.errorMessage?.hasPrefix("✗") == false)
    }

    @Test("A replay never writes into the saved memory, and a harness launch gets a throw-away preference store")
    func replayAndHarnessAreIsolated() async {
        let defaults = UserDefaults(suiteName: "agent-replay-\(UUID().uuidString)")!
        defaults.set(makeFolder().path, forKey: AgentChatState.defaultsKey)
        let chat = AgentChatState(projectRoot: makeFolder(), launcher: RecordingLauncher(), defaults: defaults)
        let events = ["@@EVENT {\"t\":\"agent-case\",\"key\":\"FAKE\",\"title\":\"Fake\",\"steps\":[{\"number\":1,\"action\":\"a\",\"data\":\"\",\"expected\":\"b\"}]}",
                      "@@EVENT {\"t\":\"agent-final\",\"verdict\":\"NONE\",\"caseKey\":\"FAKE\",\"facts\":{\"caseKey\":\"FAKE\"}}"]
        await chat.replay(lines: events, eventsPerSecond: 1000)
        #expect(chat.messages.contains { $0.kind == .testCase })
        #expect(defaults.data(forKey: AgentChatState.memoryKey) == nil, "the replay must not be saved")

        let harness = AppCompositionRoot.agentDefaults(arguments: ["app", "--agent-replay=/tmp/x.log"])
        harness.set("harness-only", forKey: "agent.repositoryPath")
        #expect(UserDefaults.standard.string(forKey: "agent.repositoryPath") != "harness-only")
        #expect(AppCompositionRoot.agentDefaults(arguments: ["app"]) === UserDefaults.standard)
    }

    @Test("A saved card is not restored when its case file no longer exists")
    func staleCardIsDropped() throws {
        let root = makeFolder()
        let defaults = UserDefaults(suiteName: "agent-stale-\(UUID().uuidString)")!
        let repository = makeFolder().path
        defaults.set(repository, forKey: AgentChatState.defaultsKey)
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        let memory = AgentMemory(repository: repository, turns: [AgentMemory.Turn(user: "u", answer: "a")], facts: ["case.json": json, "caseKey": "LOGIN-1"])
        defaults.set(try JSONEncoder().encode(memory), forKey: AgentChatState.memoryKey)

        try saveCaseFile(root, key: "LOGIN-1")
        let imported = AgentChatState(projectRoot: root, launcher: RecordingLauncher(), defaults: defaults)
        #expect(imported.messages.contains { $0.kind == .testCase }, "the old single memory is imported as a chat, card included")
        try FileManager.default.removeItem(at: root.appendingPathComponent("TestCases/LOGIN-1.json"))
        let withoutFile = AgentChatState(projectRoot: root, launcher: RecordingLauncher(), defaults: defaults)
        #expect(withoutFile.messages.contains { $0.kind == .testCase } == false)
        try saveCaseFile(root, key: "LOGIN-1")
        let withFile = AgentChatState(projectRoot: root, launcher: RecordingLauncher(), defaults: defaults)
        #expect(withFile.messages.contains { $0.kind == .testCase })
    }
}


@MainActor
@Suite("Clearing the conversation asks first")
struct AgentClearConfirmationTests {
    private func chat() -> AgentChatState {
        let defaults = UserDefaults(suiteName: "agent-clear-\(UUID().uuidString)")!
        defaults.set(makeFolder().path, forKey: AgentChatState.defaultsKey)
        return AgentChatState(projectRoot: makeFolder(), launcher: FakeAgentLauncher(process: FakeAgentProcess()), defaults: defaults)
    }

    @Test("There is nothing to confirm in an empty conversation")
    func emptyNeedsNoConfirmation() {
        let state = chat()
        state.requestClear()
        #expect(state.isConfirmingClear == false)
    }

    @Test("Asking to clear only raises the confirmation: nothing is lost until it is confirmed, and cancelling keeps everything")
    func confirmThenClear() {
        let state = chat()
        state.send("test the login screen")
        state.requestClear()
        #expect(state.isConfirmingClear)
        #expect(state.hasMessages && state.rememberedTurns == 1)
        state.cancelClear()
        #expect(state.isConfirmingClear == false && state.hasMessages)
        state.requestClear()
        state.clear()
        #expect(state.isConfirmingClear == false && state.hasMessages == false && state.rememberedTurns == 0)
    }
}

private final class QuietProcess: CaseRunHandle, @unchecked Sendable {
    let lines = AsyncStream<String> { _ in }
    func send(_ line: String) {}
    func terminate() {}
}

private struct QuietLauncher: CaseRunLaunching {
    func launch(arguments: [String]) throws -> any CaseRunHandle { QuietProcess() }
}

@MainActor
@Suite("Several chats")
struct AgentConversationsTests {
    private func defaults() -> UserDefaults {
        let store = UserDefaults(suiteName: "agent-chats-\(UUID().uuidString)")!
        store.set(makeFolder().path, forKey: AgentChatState.defaultsKey)
        return store
    }

    private func chat(_ store: UserDefaults, root: URL) -> AgentChatState {
        AgentChatState(projectRoot: root, launcher: QuietLauncher(), defaults: store)
    }

    private func answer(_ chat: AgentChatState, _ text: String) {
        chat.consume("@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: ["t": "agent-final", "verdict": "NONE", "answer": text, "facts": [String: String]()]), as: UTF8.self))
    }

    @Test("A new chat keeps the old one in the list, empty, and the first message titles it")
    func newChatKeepsTheOldOne() {
        let root = makeFolder(); let store = defaults()
        let c = chat(store, root: root)
        c.send("write a login test")
        answer(c, "done")
        let first = c.activeConversationID
        #expect(c.conversationTitle == "write a login test")

        c.newConversation()
        #expect(c.activeConversationID != first && !c.hasMessages && c.rememberedTurns == 0)
        #expect(c.conversations.map(\.id) == [first], "the saved chat is listed")
        #expect(c.conversationRows.count == 2 && c.conversationRows[0].title == ConversationSummary.untitled, "the empty chat is shown at the top")
        c.newConversation()
        #expect(c.conversationRows.count == 2, "an empty chat is not duplicated")
    }

    @Test("Switching brings back the other chat's transcript and memory")
    func switching() {
        let root = makeFolder(); let store = defaults()
        let c = chat(store, root: root)
        c.send("first topic"); answer(c, "first answer")
        let first = c.activeConversationID
        c.newConversation()
        c.send("second topic"); answer(c, "second answer")
        #expect(c.conversations.count == 2)

        c.select(first)
        #expect(c.conversationTitle == "first topic" && c.rememberedTurns == 1)
        #expect(c.messages.contains { $0.kind == .user && $0.text == "first topic" })
        #expect(!c.messages.contains { $0.text == "second topic" })
    }

    @Test("Chats survive a relaunch, and the one that was open opens again")
    func relaunch() {
        let root = makeFolder(); let store = defaults()
        let c = chat(store, root: root)
        c.send("alpha"); answer(c, "a")
        c.newConversation()
        c.send("beta"); answer(c, "b")
        let open = c.activeConversationID

        let again = chat(store, root: root)
        #expect(again.activeConversationID == open && again.conversationTitle == "beta")
        #expect(again.conversations.count == 2)
    }

    @Test("Rename works on the open chat and on another one")
    func rename() {
        let root = makeFolder(); let store = defaults()
        let c = chat(store, root: root)
        c.send("alpha"); answer(c, "a")
        let first = c.activeConversationID
        c.newConversation()
        c.send("beta"); answer(c, "b")
        c.rename(first, to: "  Login flow ")
        c.rename(c.activeConversationID, to: "Settings flow")
        #expect(Set(c.conversations.map(\.title)) == ["Login flow", "Settings flow"])
        c.rename(first, to: "   ")
        #expect(c.conversations.contains { $0.title == "Login flow" }, "a blank title is ignored")
    }

    @Test("Deleting the open chat opens the next one; deleting the last leaves an empty chat")
    func delete() {
        let root = makeFolder(); let store = defaults()
        let c = chat(store, root: root)
        c.send("alpha"); answer(c, "a")
        let first = c.activeConversationID
        c.newConversation()
        c.send("beta"); answer(c, "b")
        let second = c.activeConversationID

        c.delete(second)
        #expect(c.activeConversationID == first && c.conversationTitle == "alpha")
        c.delete(first)
        #expect(c.conversations.isEmpty && !c.hasMessages && c.conversationRows.count == 1)
        #expect(chat(store, root: root).conversations.isEmpty, "the files are gone")
    }

    @Test("Clearing a chat removes it from the list")
    func clearRemoves() {
        let root = makeFolder(); let store = defaults()
        let c = chat(store, root: root)
        c.send("alpha"); answer(c, "a")
        c.clear()
        #expect(c.conversations.isEmpty && !c.hasMessages)
    }

    @Test("A damaged chat file does not stop the app from opening")
    func damagedFile() throws {
        let root = makeFolder(); let store = defaults()
        let c = chat(store, root: root)
        c.send("alpha"); answer(c, "a")
        let file = root.appendingPathComponent(".runs/chats/\(c.activeConversationID.uuidString).json")
        try Data("not json".utf8).write(to: file)
        let again = chat(store, root: root)
        #expect(again.conversationTitle == ConversationSummary.untitled && !again.hasMessages)
    }
}

@MainActor
@Suite("Agent flow in the chat")
struct AgentChatFlowTests {
    private func make(_ launcher: RecordingLauncher, store: UserDefaults? = nil) -> (AgentChatState, UserDefaults) {
        let defaults = store ?? UserDefaults(suiteName: "agent-flow-\(UUID().uuidString)")!
        defaults.set(makeFolder().path, forKey: AgentChatState.defaultsKey)
        return (AgentChatState(projectRoot: makeFolder(), launcher: launcher, defaults: defaults), defaults)
    }

    @Test("The default flow passes no flag; another flow is handed to the agent process")
    func flagOnlyWhenChanged() {
        let launcher = RecordingLauncher()
        let (chat, _) = make(launcher)
        chat.send("one")
        #expect(launcher.arguments[0].contains { $0.hasPrefix("--flow=") } == false)

        chat.stop()
        chat.setFlow(.authorOnly)
        chat.send("two")
        let flag = launcher.arguments[1].first { $0.hasPrefix("--flow=") }
        #expect(flag.flatMap { AgentFlow.decode(String($0.dropFirst(7))) } == AgentFlow.authorOnly)
    }

    @Test("The team strip follows the flow, and the choice is remembered")
    func teamAndPersistence() {
        let launcher = RecordingLauncher()
        let (chat, defaults) = make(launcher)
        chat.setFlow(.repositoryQuestions)
        #expect(chat.agents.map(\.id) == ["Orchestrator", "RepoAnalyst"])
        let (again, _) = make(launcher, store: defaults)
        #expect(again.flow == .repositoryQuestions && again.agents.map(\.id) == ["Orchestrator", "RepoAnalyst"])
    }

    @Test("Changing the flow in a running conversation restarts the agents and says so; it is refused while they work")
    func changeWhileRunning() {
        let launcher = RecordingLauncher()
        let (chat, _) = make(launcher)
        chat.send("one")
        #expect(chat.isBusy)
        chat.setFlow(.authorOnly)
        #expect(chat.flow == .full, "refused while the agents are working")

        chat.consume("@@EVENT {\"t\":\"agent-final\",\"verdict\":\"NONE\",\"answer\":\"ok\"}")
        chat.setFlow(.authorOnly)
        #expect(chat.flow == .authorOnly && chat.isConversationActive == false)
        #expect(chat.messages.last?.kind == .notice)
    }

    @Test("A flow with no specialist is ignored")
    func unusable() {
        let (chat, _) = make(RecordingLauncher())
        var empty = AgentFlow.full
        for role in AgentFlow.Role.allCases { empty[role].enabled = false }
        chat.setFlow(empty)
        #expect(chat.flow == .full)
    }
}

private actor FakeDeviceControl: DeviceControlling {
    private(set) var ran: [DeviceCommand] = []
    private let booted = DeviceTarget(udid: "SIM-1", name: "iPhone 17 Pro", kind: .simulator, state: "Booted", osVersion: "iOS 26.5")
    func targets() async throws -> [DeviceTarget] { [booted] }
    func defaultTarget() async -> DeviceTarget? { booted }
    func run(_ command: DeviceCommand, on target: DeviceTarget, context: DeviceValidationContext) async throws -> DeviceCommandResult {
        ran.append(command)
        return DeviceCommandResult(text: "did \(command.kind.rawValue) on \(target.name)")
    }
}

@MainActor
@Suite("Device commands in the chat")
struct AgentDeviceChatTests {
    private let launcher = RecordingLauncher()
    private let device = FakeDeviceControl()

    private func chat(withDevice: Bool = true) -> AgentChatState {
        let defaults = UserDefaults(suiteName: "agent-device-\(UUID().uuidString)")!
        defaults.set(makeFolder().path, forKey: AgentChatState.defaultsKey)
        let state = AgentChatState(projectRoot: makeFolder(), launcher: launcher, defaults: defaults, deviceControl: withDevice ? device : nil)
        state.send("hello")   // starts the agent process the replies are written to
        return state
    }

    private func request(_ chat: AgentChatState, _ id: String, _ kind: String, _ arguments: [String: Any] = [:]) {
        let event: [String: Any] = ["t": "agent-device-request", "id": id, "command": ["kind": kind, "arguments": arguments]]
        chat.consume("@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self))
    }

    /// The text of the `device-result` for `id`, once the app has written it.
    private func result(_ id: String) async -> String? {
        for _ in 0..<100 {
            for line in launcher.processes.first?.sent ?? [] {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["t"] as? String == "device-result", object["id"] as? String == id else { continue }
                return object["text"] as? String
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private func waitForApproval(_ chat: AgentChatState) async -> DeviceApproval? {
        for _ in 0..<100 { if let approval = chat.deviceApproval { return approval }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return nil
    }

    @Test("A read-only command runs at once, without a question, on the booted simulator")
    func readOnly() async {
        let chat = chat()
        request(chat, "a", "describe_screen")
        #expect(await result("a") == "did describe_screen on iPhone 17 Pro")
        #expect(chat.deviceApproval == nil && !chat.isWaitingForPerson)
    }

    @Test("A reversible command asks first; allowing it once runs it, and the next one asks again")
    func reversibleOnce() async {
        let chat = chat()
        request(chat, "a", "press_button", ["button": "HOME"])
        let approval = await waitForApproval(chat)
        #expect(approval?.phrase == "Press the HOME button" && approval?.offersChatGrant == true && chat.isWaitingForPerson)
        let before = await device.ran.count
        #expect(before == 0, "nothing runs before the answer")
        chat.answerDevice(.approveOnce)
        #expect(await result("a") == "did press_button on iPhone 17 Pro")

        request(chat, "b", "press_button", ["button": "LOCK"])
        #expect(await waitForApproval(chat)?.id == "b")
        chat.answerDevice(.deny)
        #expect(await result("b")?.hasPrefix("FAILED: The person did not allow this command") == true)
        let after = await device.ran.count
        #expect(after == 1)
    }

    @Test("Allowing the chat lets reversible commands run unasked, but a destructive one still asks, every time, with no chat grant offered")
    func chatGrant() async {
        let chat = chat()
        request(chat, "a", "open_url", ["url": "https://example.com"])
        _ = await waitForApproval(chat)
        chat.answerDevice(.allowForChat)
        #expect(await result("a") != nil)

        request(chat, "b", "set_location", ["latitude": 10, "longitude": 20])
        #expect(await result("b") == "did set_location on iPhone 17 Pro", "no question this time")

        request(chat, "c", "uninstall_app", ["bundle_id": "com.apple.mobilesafari"])
        let destructive = await waitForApproval(chat)
        #expect(destructive?.risk == .destructive && destructive?.offersChatGrant == false)
        chat.answerDevice(.allowForChat)   // not honoured as a grant for destructive commands
        #expect(await result("c") != nil)
        request(chat, "d", "uninstall_app", ["bundle_id": "com.apple.mobilesafari"])
        #expect(await waitForApproval(chat)?.id == "d", "asked again")
        chat.answerDevice(.deny)
    }

    @Test("An invalid command is refused with the reason, without a question and without reaching the device")
    func invalid() async {
        let chat = chat()
        request(chat, "a", "open_url", ["url": "file:///etc/passwd"])
        #expect(await result("a")?.contains("FAILED: The command is not valid") == true)
        request(chat, "b", "tap")
        #expect(await result("b")?.contains("give a label, an identifier, or both x and y") == true)
        let ran = await device.ran.count
        #expect(chat.deviceApproval == nil && ran == 0)
    }

    @Test("Without idb the agents are told device control is not available")
    func noIDB() async {
        let chat = chat(withDevice: false)
        request(chat, "a", "list_apps")
        #expect(await result("a")?.contains("Device control is not available") == true)
    }

    @Test("Stopping the agents while a command waits denies it: the question closes and nothing runs")
    func stopAndNewChat() async {
        let chat = chat()
        request(chat, "a", "press_button", ["button": "HOME"])
        _ = await waitForApproval(chat)
        chat.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)   // the agent process is gone: there is no one to send the denial to
        let ran = await device.ran.count
        #expect(chat.deviceApproval == nil && ran == 0)
    }
}
