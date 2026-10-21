import Testing
import Foundation
@testable import AgentCore
@testable import AgentGateway
@testable import TestCaseSources

@Suite("Drafting cases from requirements")
struct StoryDrafterTests {
    private let gherkin = """
    Feature: Login
      Scenario: Valid login
        Given the app is open on the login screen
        When I tap "Sign in" with valid credentials
        Then the Home tab is shown
        And the greeting says "Welcome"
      Scenario: Empty password
        When I tap "Sign in" with no password
    """

    @Test("Gherkin scenarios become cases: Then and later And lines are the expected result of the step before; a missing Then is flagged")
    func gherkinDrafts() {
        let drafts = StoryDrafter.drafts(from: gherkin)
        #expect(drafts.map(\.title) == ["Login: Valid login", "Login: Empty password"])
        let first = drafts[0].steps
        #expect(first.count == 2 && first[0].action == "the app is open on the login screen")
        #expect(first[1].action == "I tap \"Sign in\" with valid credentials" && first[1].expected == "the Home tab is shown; the greeting says \"Welcome\"")
        #expect(first[0].expected.hasPrefix("The screen shows the result of") && drafts[0].notes.count == 1)
        #expect(drafts[1].notes.count == 1, "the scenario with no Then says so")
    }

    @Test("A story without Gherkin uses its list as acceptance criteria, one step each, under the first heading")
    func criteria() {
        let drafts = StoryDrafter.drafts(from: "# Share a result\nSome prose.\n- Share sheet opens\n2. Reminders is listed\n* \n")
        #expect(drafts.count == 1 && drafts[0].title == "Share a result")
        #expect(drafts[0].steps.map(\.expected) == ["Share sheet opens", "Reminders is listed"] && drafts[0].steps.map(\.number) == [1, 2])
        #expect(StoryDrafter.drafts(from: "Just some prose with nothing to test.").isEmpty)
    }

    @Test("A long scenario is cut at the 25 steps a case holds, with a note")
    func capped() {
        let text = "Scenario: Long\n" + (1...30).map { "When step \($0)" }.joined(separator: "\n")
        let draft = StoryDrafter.drafts(from: text)[0]
        #expect(draft.steps.count == 25 && draft.notes.contains { $0.contains("only the first 25") })
    }

    @Test("generate_cases previews by default, writes on request with the next free keys, and refuses files outside the project")
    func tool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("TestCases"), withIntermediateDirectories: true)
        let gateway = Gateway(tools: GatewayCatalogue.tools(GatewayServices(projectRoot: root, deviceControl: nil, launcher: nil)))
        let preview = await gateway.call("generate_cases", arguments: ["text": .string(gherkin)])
        #expect(!preview.isError && preview.plainText.contains("GEN-1") && preview.plainText.contains("GEN-2") && preview.plainText.contains("Preview only"))
        #expect(FileTestCaseStore(directory: root.appendingPathComponent("TestCases")).keys().isEmpty)
        let written = await gateway.call("generate_cases", arguments: ["text": .string(gherkin), "write": .bool(true), "key_prefix": .string("login")])
        #expect(written.plainText.contains("LOGIN-1 — Login: Valid login (2 steps) saved"))
        let again = await gateway.call("generate_cases", arguments: ["text": .string(gherkin), "write": .bool(true), "key_prefix": .string("login")])
        #expect(again.plainText.contains("LOGIN-3") && FileTestCaseStore(directory: root.appendingPathComponent("TestCases")).keys() == ["LOGIN-1", "LOGIN-2", "LOGIN-3", "LOGIN-4"])
        try Data("Scenario: S\nWhen x\nThen y".utf8).write(to: root.appendingPathComponent("story.md"))
        let fromFile = await gateway.call("generate_cases", arguments: ["file": .string("story.md")])
        #expect(!fromFile.isError)
        let outside = await gateway.call("generate_cases", arguments: ["file": .string("/etc/hosts")])
        let up = await gateway.call("generate_cases", arguments: ["file": .string("../../etc/hosts")])
        #expect(outside.isError && up.isError)
        #expect(await gateway.call("generate_cases", arguments: ["text": .string("nothing here")]).isError)
    }
}
