import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Workspace navigation")
struct WorkspaceModelsTests {
    @Test func testSidebarListFollowsTheSection() {
        #expect(WorkspaceSection.agent.sidebarList == .chats && WorkspaceSection.operate.sidebarList == .sessions)
        for section in [WorkspaceSection.run, .tests, .history, .skills, .simulator] { #expect(section.sidebarList == .none, Comment(rawValue: section.title)) }
    }

    @Test func testSections() {
        #expect(WorkspaceSection.allCases.map(\.title) == ["Run", "Tests", "History", "Skills", "Simulator", "Operate", "Agent"])
        #expect(WorkspaceSection.allCases.map(\.shortcutDigit) == [1, 2, 3, 4, 5, 6, 7])
        #expect(WorkspaceSection.allCases.allSatisfy { !$0.symbolName.isEmpty })
    }

    @Test func testLaunchNamesIncludeTheOldCasesAlias() {
        #expect(WorkspaceSection(launchName: "Cases") == .run)
        #expect(WorkspaceSection(launchName: "run") == .run)
        #expect(WorkspaceSection(launchName: "History") == .history)
        #expect(WorkspaceSection(launchName: "Timeline") == nil)
    }

    @MainActor @Test func testWorkspaceStateNavigation() {
        let w = WorkspaceState()
        #expect(w.section == .run)
        w.show(.history); #expect(w.section == .history)
    }
}
