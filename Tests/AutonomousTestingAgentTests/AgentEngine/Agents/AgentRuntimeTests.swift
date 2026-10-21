import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine
import TestCaseSources

/// A model that answers from a script, one scripted turn per request.
private final class ScriptedLLM: ToolCallingLLM, @unchecked Sendable {
    let modelName = "scripted"
    private let lock = NSLock()
    private var turns: [[AgentEvent]]
    private(set) var seen: [[AgentMessage]] = []

    init(_ turns: [[AgentEvent]]) { self.turns = turns }

    func respond(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let turn: [AgentEvent] = lock.withLock { seen.append(messages); return turns.isEmpty ? [.textDelta("done")] : turns.removeFirst() }
        return AsyncThrowingStream { continuation in
            turn.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private func call(_ name: String, _ arguments: [String: AnyCodableValue] = [:], id: String = "c1") -> AgentEvent {
    .toolCall(ToolCall(id: id, name: name, arguments: arguments), opaque: nil)
}

private func repository() throws -> URL {
    let root = ProductFixtures.tempDir()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try "struct Login { let title = \"Sign in\" }\n".write(to: root.appendingPathComponent("Sources/Login.swift"), atomically: true, encoding: .utf8)
    try "API_KEY=secret\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "key".write(to: root.appendingPathComponent("signing.p12"), atomically: true, encoding: .utf8)
    return root
}

@Suite("Repository sandbox")
struct RepoSandboxTests {
    @Test("Files inside the repository are readable and searchable")
    func readsInside() throws {
        let sandbox = RepoSandbox(root: try repository())
        #expect(try sandbox.read("Sources/Login.swift").contains("Sign in"))
        #expect(try sandbox.search("sign in").first?.hasPrefix("Sources/Login.swift:1:") == true)
        #expect(try sandbox.list(".").contains("Sources/"))
    }

    @Test("Paths outside the root, secrets and keys are refused")
    func refuses() throws {
        let sandbox = RepoSandbox(root: try repository())
        #expect(throws: RepoSandbox.Refused.self) { try sandbox.read("../outside.txt") }
        #expect(throws: RepoSandbox.Refused.self) { try sandbox.read("/etc/hosts") }
        #expect(throws: RepoSandbox.Refused.self) { try sandbox.read(".env") }
        #expect(throws: RepoSandbox.Refused.self) { try sandbox.read("signing.p12") }
        #expect(try !sandbox.list(".").contains(".env"))
        #expect(try sandbox.search("secret").isEmpty)
    }

    @Test("A symlink that leaves the repository is refused")
    func symlinkEscape() throws {
        let root = try repository()
        let outside = ProductFixtures.tempDir()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "private".write(to: outside.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: RepoSandbox.Refused.self) { try RepoSandbox(root: root).read("link/note.txt") }
    }
}

@Suite("Agent loop")
struct AgentLoopTests {
    private func agent(_ llm: ScriptedLLM, tools: [AgentTool], maxTurns: Int = 4) -> Agent {
        Agent(name: "Tester", role: "r", system: "s", tools: tools, llm: llm, maxTurns: maxTurns)
    }

    @Test("A tool call runs, its result goes back to the model, and the model's text ends the loop")
    func toolRoundTrip() async throws {
        let llm = ScriptedLLM([[call("echo", ["text": .string("hi")])], [.textDelta("all done")]])
        let echo = AgentTool(name: "echo", description: "", properties: ["text": Schema.string("")]) { "echoed \($0.string("text") ?? "")" }
        let answer = try await agent(llm, tools: [echo]).run(task: "go", state: AgentState(), reporter: AgentReporter())
        #expect(answer == "all done")
        #expect(llm.seen.last?.contains(.toolResult(callID: "c1", name: "echo", content: "echoed hi")) == true)
    }

    @Test("A failing or unknown tool becomes a result the model can read, not a crash")
    func toolErrors() async throws {
        let llm = ScriptedLLM([[call("boom", id: "a"), call("missing", id: "b")], [.textDelta("ok")]])
        let boom = AgentTool(name: "boom", description: "") { _ in throw RepoSandbox.Refused(reason: "nope") }
        _ = try await agent(llm, tools: [boom]).run(task: "go", state: AgentState(), reporter: AgentReporter())
        let results = llm.seen.last ?? []
        #expect(results.contains(.toolResult(callID: "a", name: "boom", content: "Error: nope")))
        #expect(results.contains(.toolResult(callID: "b", name: "missing", content: "Error: there is no tool named missing.")))
    }

    @Test("The turn limit forces a text answer")
    func turnLimit() async throws {
        let loop = [AgentEvent.toolCall(ToolCall(id: "x", name: "echo", arguments: [:]), opaque: nil)]
        let llm = ScriptedLLM([loop, loop, [.textDelta("forced")]])
        let echo = AgentTool(name: "echo", description: "") { _ in "r" }
        let answer = try await agent(llm, tools: [echo], maxTurns: 2).run(task: "go", state: AgentState(), reporter: AgentReporter())
        #expect(answer == "forced")
    }

    @Test("The conversation's model-call budget stops the agent")
    func budget() async {
        let llm = ScriptedLLM([[.textDelta("x")]])
        await #expect(throws: Agent.Failure.self) {
            _ = try await agent(llm, tools: []).run(task: "go", state: AgentState(maxLLMCalls: 0), reporter: AgentReporter())
        }
    }
}

@Suite("Case authoring tool")
struct CaseAuthorToolTests {
    private func writer(_ root: URL) -> (AgentTool, AgentState) {
        let state = AgentState()
        return (AgentTools.author(projectRoot: root, state: state, reporter: AgentReporter()).first { $0.spec.name == "write_test_case" }!, state)
    }

    private func args(key: String = "AGENT-T-1", steps: [AnyCodableValue]) -> [String: AnyCodableValue] {
        ["key": .string(key), "title": .string("T"), "bundle_id": .string("com.apple.mobilesafari"), "steps": .array(steps)]
    }

    private func step(_ action: String, expected: String) -> AnyCodableValue {
        .dictionary(["action": .string(action), "data": .string(""), "expected": .string(expected)])
    }

    @Test("A valid case is saved in the test case format and remembered in the shared state")
    func saves() async throws {
        let root = ProductFixtures.tempDir()
        let (tool, state) = writer(root)
        _ = try await tool.run(args(steps: [step("Open Safari", expected: "Safari is open"), step("Tap the address bar", expected: "Keyboard shows")]))
        let saved = try JSONDecoder().decode(TestCase.self, from: Data(contentsOf: root.appendingPathComponent("TestCases/AGENT-T-1.json")))
        #expect(saved.steps.map(\.number) == [1, 2])
        #expect(saved.source == "agent")
        #expect(await state.caseKey == "AGENT-T-1")
        #expect(await state.bundleID == "com.apple.mobilesafari")
    }

    @Test("Bad keys, empty steps and a hand-written case that would be overwritten are refused")
    func refuses() async throws {
        let root = ProductFixtures.tempDir()
        let (tool, _) = writer(root)
        await #expect(throws: RepoSandbox.Refused.self) { _ = try await tool.run(args(key: "../evil", steps: [step("a", expected: "b")])) }
        await #expect(throws: RepoSandbox.Refused.self) { _ = try await tool.run(args(steps: [])) }
        await #expect(throws: RepoSandbox.Refused.self) { _ = try await tool.run(args(steps: [step("", expected: "b")])) }
        let folder = root.appendingPathComponent("TestCases")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(TestCase(key: "HAND-1", title: "x", source: "files", steps: [])).write(to: folder.appendingPathComponent("HAND-1.json"))
        await #expect(throws: RepoSandbox.Refused.self) { _ = try await tool.run(args(key: "HAND-1", steps: [step("a", expected: "b")])) }
    }
}

@Suite("Tool-calling wire format")
struct ToolCallingWireTests {
    private let history: [AgentMessage] = [
        .user("hi"),
        .assistant(text: "", calls: [ToolCall(id: "c1", name: "list_dir", arguments: ["path": .string(".")])], reasoning: "thinking", opaque: ["c1": "sig"]),
        .toolResult(callID: "c1", name: "list_dir", content: "Sources/"),
    ]
    private let tool = AgentToolSpec(name: "list_dir", description: "d", schema: Schema.object(["path": Schema.string("p")], required: ["path"]))

    @Test("DeepSeek: assistant calls, tool results and the tool list use the OpenAI shape")
    func deepSeek() throws {
        let body = DeepSeekToolCaller(apiKey: "k", model: "deepseek-reasoner").requestBody(system: "sys", messages: history, tools: [tool])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        let calls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect((calls[0]["function"] as? [String: Any])?["arguments"] as? String == #"{"path":"."}"#)
        #expect(messages[2]["reasoning_content"] as? String == "thinking")
        #expect(messages[3]["tool_call_id"] as? String == "c1")
        #expect(body["stream"] as? Bool == true)
        #expect((body["tools"] as? [[String: Any]])?.count == 1)
    }

    @Test("Gemini: function calls keep their signature and parallel results share one user turn")
    func gemini() throws {
        var messages = history
        messages.append(.toolResult(callID: "c2", name: "read_file", content: "text"))
        let body = GeminiToolCaller(apiKey: "k", model: "m").requestBody(system: "sys", messages: messages, tools: [tool])
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let model = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(model[0]["thoughtSignature"] as? String == "sig")
        #expect((contents[2]["parts"] as? [[String: Any]])?.count == 2)
    }
}


@Suite("Repository knowledge")
struct RepoKnowledgeTests {
    private func xcodeStyleRepository() throws -> URL {
        let root = ProductFixtures.tempDir()
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("Targets/App/LoginView.swift", """
        import SwiftUI
        struct LoginView: View {
            var body: some View {
                VStack {
                    Text("Welcome back")
                    TextField("Username", text: .constant(""))
                    Button("Log In") {}.accessibilityIdentifier("login-button")
                }.navigationTitle("Sign in")
            }
        }
        enum AppTab: CaseIterable { case home, settings }
        """)
        try write("Targets/App/HomeView.swift", "import SwiftUI\nstruct HomeView: View { var body: some View { LoginView() } }\n")
        try write("Targets/UITests/LoginUITests.swift", "struct LoginUITests { let id = \"hidden-test-only\" }\n")
        try write("Derived/Sources/Gen.swift", "struct GeneratedThing {}\n")
        try write("Targets/App/Assets.xcassets/Icon.imageset/Contents.json", "{\"images\": []}")
        try write("App.xcodeproj/project.pbxproj", "x\n\t\tPRODUCT_BUNDLE_IDENTIFIER = com.apple.mobilesafari;\n\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.appTests;\nmore\n")
        return root
    }

    private func knowledge(_ root: URL) -> RepoKnowledge {
        RepoKnowledge(sandbox: RepoSandbox(root: root), projectRoot: ProductFixtures.tempDir())
    }

    @Test("The overview finds screens, navigation enums and the bundle id in an Xcode-style layout, and leaves out tests and generated code")
    func overview() throws {
        let text = RepoInsights.overview(knowledge(try xcodeStyleRepository()))
        #expect(text.contains("LoginView") && text.contains("HomeView"))
        #expect(text.contains("AppTab") && text.contains("home, settings"))
        #expect(text.contains("com.apple.mobilesafari"))
        #expect(!text.contains("LoginUITests") && !text.contains("GeneratedThing"))
    }

    @Test("ui_strings lists the words on a screen and the accessibility identifiers")
    func uiStrings() throws {
        let text = RepoInsights.uiStrings(knowledge(try xcodeStyleRepository()), path: "Targets/App")
        for expected in ["Welcome back", "Username", "Log In", "login-button", "Sign in"] { #expect(text.contains(expected), "missing \(expected)") }
    }

    @Test("file_outline and describe_symbol answer from the index; describe names the files that use a type")
    func outlineAndDescribe() throws {
        let k = knowledge(try xcodeStyleRepository())
        #expect(RepoInsights.outline(k, path: "Targets/App/LoginView.swift").contains("struct LoginView"))
        let described = RepoInsights.describe(k, name: "LoginView")
        #expect(described.contains("conforms to: View") && described.contains("used in: Targets/App/HomeView.swift"))
        #expect(RepoInsights.describe(k, name: "Nope").hasPrefix("No declaration named Nope"))
    }

    @Test("Search is case-insensitive, capped per file, and never reads asset catalogs or the project file's other lines")
    func search() throws {
        let k = knowledge(try xcodeStyleRepository())
        #expect(k.search("WELCOME BACK").first?.hasPrefix("Targets/App/LoginView.swift:") == true)
        #expect(k.search("images").isEmpty)
        #expect(k.search("PRODUCT_BUNDLE_IDENTIFIER").count == 2)
        #expect(k.search("e", limit: 5).count <= 5)
    }
}

@Suite("Agent loop limits")
struct AgentLoopLimitTests {
    @Test("Calls made together run in parallel but their results return in the model's order")
    func parallelOrder() async throws {
        let calls: [AgentEvent] = [call("slow", id: "a"), call("fast", id: "b")]
        let llm = ScriptedLLM([calls, [.textDelta("ok")]])
        let slow = AgentTool(name: "slow", description: "") { _ in try await Task.sleep(nanoseconds: 150_000_000); return "S" }
        let fast = AgentTool(name: "fast", description: "") { _ in "F" }
        let agent = Agent(name: "T", role: "r", system: "s", tools: [slow, fast], llm: llm, maxTurns: 3)
        let started = Date()
        _ = try await agent.run(task: "go", state: AgentState(), reporter: AgentReporter())
        let results = (llm.seen.last ?? []).compactMap { message -> String? in if case .toolResult(let id, _, _) = message { return id } else { return nil } }
        #expect(results == ["a", "b"])
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("Past the tool-call budget the tools stop running and tell the model to answer")
    func toolBudget() async throws {
        let llm = ScriptedLLM([[call("echo", id: "1"), call("echo", id: "2"), call("echo", id: "3")], [.textDelta("done")]])
        let ran = LockedCounter()
        let echo = AgentTool(name: "echo", description: "", parallelSafe: false) { _ in ran.increment(); return "r" }
        var agent = Agent(name: "T", role: "r", system: "s", tools: [echo], llm: llm, maxTurns: 3)
        agent.maxToolCalls = 2
        _ = try await agent.run(task: "go", state: AgentState(), reporter: AgentReporter())
        #expect(ran.value == 2)
        let last = (llm.seen.last ?? []).last
        if case .toolResult(_, _, let content)? = last { #expect(content.hasPrefix("Tool budget spent")) } else { Issue.record("no tool result") }
    }

    @Test("A long tool result is clipped as it enters the conversation")
    func clipping() async throws {
        let llm = ScriptedLLM([[call("big")], [.textDelta("ok")]])
        let big = AgentTool(name: "big", description: "") { _ in String(repeating: "x", count: 20_000) }
        _ = try await Agent(name: "T", role: "r", system: "s", tools: [big], llm: llm, maxTurns: 3).run(task: "go", state: AgentState(), reporter: AgentReporter())
        if case .toolResult(_, _, let content)? = (llm.seen.last ?? []).last { #expect(content.count < Agent.maxResultCharacters + 100) } else { Issue.record("no tool result") }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}


@Suite("Agent facts")
struct AgentFactsTests {
    @Test("Facts survive a restart and are written into the next task so finished work is not redone")
    func factsRoundTrip() async {
        let before = AgentState()
        await before.setCase(key: "CASE-1", bundleID: "com.apple.mobilesafari")
        await before.setReport("RepoAnalyst", "Login lives in LoginView; id error-message")
        await before.setLastRun("Outcome: PASSED")
        let facts = await before.facts()
        #expect(facts["caseKey"] == "CASE-1" && facts["report.RepoAnalyst"] == "Login lives in LoginView; id error-message")

        let after = AgentState()
        await after.restore(facts: facts)
        let block = await after.factsBlock()
        #expect(block.contains("CASE-1") && block.contains("com.apple.mobilesafari") && block.contains("error-message") && block.contains("PASSED"))
        #expect(await AgentState().factsBlock().isEmpty)
    }

    @Test("A long report is kept short enough to resend cheaply")
    func reportsAreCapped() async {
        let state = AgentState()
        await state.setReport("RepoAnalyst", String(repeating: "x", count: 20_000))
        #expect(await state.facts()["report.RepoAnalyst"]?.count == 3000)
    }
}


@Suite("Agent approval wait")
struct AgentInboxTimeoutTests {
    @Test("A wait with a timeout gives up with nil instead of waiting for ever")
    func timesOut() async {
        let inbox = AgentInbox()
        let started = Date()
        let answer = await inbox.next(kind: "answer", id: "x", timeout: 0.3)
        #expect(answer == nil)
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
