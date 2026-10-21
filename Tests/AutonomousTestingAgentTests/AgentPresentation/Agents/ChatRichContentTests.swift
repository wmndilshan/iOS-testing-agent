import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    private func kinds(_ code: String, _ language: String) -> [(CodeTokenKind, String)] {
        SyntaxHighlighter.tokens(code, language: language).map { ($0.kind, $0.text) }
    }

    @Test("Swift: keywords, types, strings, numbers, comments and attributes")
    func swift() {
        let tokens = SyntaxHighlighter.tokens("@MainActor struct Login { let title = \"Sign in\" // label\n var n = 42 }", language: "swift")
        func has(_ kind: CodeTokenKind, _ text: String) -> Bool { tokens.contains { $0.kind == kind && $0.text == text } }
        #expect(has(.attribute, "@MainActor") && has(.keyword, "struct") && has(.type, "Login") && has(.keyword, "let"))
        #expect(has(.string, "\"Sign in\"") && has(.comment, "// label") && has(.number, "42"))
        #expect(tokens.map(\.text).joined() == "@MainActor struct Login { let title = \"Sign in\" // label\n var n = 42 }", "no character is lost")
    }

    @Test("JSON: keys differ from string values; literals are keywords")
    func json() {
        let tokens = SyntaxHighlighter.tokens("{\"name\": \"x\", \"ok\": true, \"n\": 3}", language: "json")
        #expect(tokens.contains { $0.kind == .key && $0.text == "\"name\"" })
        #expect(tokens.contains { $0.kind == .string && $0.text == "\"x\"" })
        #expect(tokens.contains { $0.kind == .keyword && $0.text == "true" } && tokens.contains { $0.kind == .number && $0.text == "3" })
    }

    @Test("Python and shell comments, and block comments, run to their end")
    func comments() {
        #expect(kinds("x = 1  # note", "python").contains { $0 == (.comment, "# note") })
        #expect(kinds("echo $HOME # done", "bash").contains { $0 == (.attribute, "$HOME") })
        #expect(kinds("a /* b\nc */ d", "swift").contains { $0 == (.comment, "/* b\nc */") })
    }

    @Test("Unknown languages and oversized input stay plain, and an unterminated string does not hang")
    func fallbacks() {
        #expect(SyntaxHighlighter.tokens("anything", language: "brainfuck") == [CodeToken(kind: .plain, text: "anything")])
        let big = String(repeating: "x", count: SyntaxHighlighter.maxCharacters + 1)
        #expect(SyntaxHighlighter.tokens(big, language: "swift").count == 1)
        #expect(SyntaxHighlighter.tokens("let s = \"never closed", language: "swift").map(\.text).joined() == "let s = \"never closed")
    }
}

@Suite("Markdown task lists")
struct MarkdownTaskTests {
    @Test("Checklist items become task blocks; plain bullets stay bullets")
    func tasks() {
        let blocks = MarkdownParser.parse("- [x] Write the case\n- [ ] Run it\n  - [ ] nested\n- plain")
        #expect(blocks == [.task(indent: 0, done: true, text: "Write the case"), .task(indent: 0, done: false, text: "Run it"),
                           .task(indent: 1, done: false, text: "nested"), .listItem(indent: 0, marker: "•", text: "plain")])
    }
}

@Suite("Agent plan")
struct AgentPlanTests {
    private func turn(sections: [(String, Bool, Bool)], busy: Bool, flow: AgentFlow = .full, approval: Bool = false) -> AgentPlan? {
        var messages = [AgentChatMessage(kind: .user, agent: "", text: "test it")]
        for (agent, active, failed) in sections {
            messages.append(AgentChatMessage(kind: .handoff, agent: "Orchestrator", text: "task", toolName: agent))
            var tool = AgentChatMessage(kind: .tool, agent: agent, text: "{}")
            tool.toolName = "read_file"; tool.result = "r"; tool.succeeded = !failed
            messages.append(tool)
            _ = active
        }
        let items = AgentTimeline.build(messages, isBusy: busy, flow: flow, awaitingApproval: approval)
        return items.compactMap { if case .plan(let p) = $0 { p } else { nil } }.first
    }

    @Test("A busy turn with no work yet lists every step as pending, under the person's message")
    func pending() throws {
        let items = AgentTimeline.build([AgentChatMessage(kind: .user, agent: "", text: "go")], isBusy: true, flow: .full)
        #expect(items.count == 2)
        guard case .plan(let plan) = items[1] else { Issue.record("no plan"); return }
        #expect(plan.steps.map(\.agent) == ["RepoAnalyst", "CaseAuthor", "Runner", "Validator"])
        #expect(plan.steps.allSatisfy { $0.state == .pending } && !plan.isFinished)
    }

    @Test("Steps follow the sections: finished ones are done, the open one is working, the rest wait")
    func progress() throws {
        let plan = try #require(turn(sections: [("RepoAnalyst", false, false), ("CaseAuthor", true, false)], busy: true))
        #expect(plan.steps.map(\.state) == [.done, .working, .pending, .pending])
        #expect(plan.completedCount == 1)
    }

    @Test("A finished turn marks steps that never ran as skipped, and tool failures as issues")
    func finished() throws {
        let plan = try #require(turn(sections: [("RepoAnalyst", false, true), ("CaseAuthor", false, false)], busy: false))
        #expect(plan.steps.map(\.state) == [.issues, .done, .skipped, .skipped] && plan.isFinished)
    }

    @Test("The Runner waits for approval while a question is open")
    func approval() throws {
        let plan = try #require(turn(sections: [("Runner", true, false)], busy: true, approval: true))
        #expect(plan.steps.first { $0.agent == "Runner" }?.state == .waitingForApproval)
    }

    @Test("The plan follows the flow, there is one per turn, and no plan is built without a flow")
    func flowAndTurns() throws {
        let plan = try #require(turn(sections: [("RepoAnalyst", false, false)], busy: false, flow: .repositoryQuestions))
        #expect(plan.steps.map(\.agent) == ["RepoAnalyst"])

        let messages = [AgentChatMessage(kind: .user, agent: "", text: "one"), AgentChatMessage(kind: .handoff, agent: "Orchestrator", text: "t", toolName: "RepoAnalyst"),
                        AgentChatMessage(kind: .user, agent: "", text: "two")]
        let withFlow = AgentTimeline.build(messages, isBusy: false, flow: .full)
        #expect(withFlow.filter { if case .plan = $0 { true } else { false } }.count == 1, "the second turn did no work")
        #expect(withFlow.map(\.id).count == Set(withFlow.map(\.id)).count, "ids are unique so a list can show them all")
        #expect(AgentTimeline.build(messages, isBusy: false).contains { if case .plan = $0 { true } else { false } } == false)
    }

    @Test("Suggestions depend on the verdict")
    func suggestions() {
        #expect(AgentSuggestions.afterVerdict("FAIL").first == "Fix the case and run it again")
        #expect(AgentSuggestions.afterVerdict("INCOMPLETE").first == "Continue")
        #expect(AgentSuggestions.afterVerdict("NONE").isEmpty)
    }
}
