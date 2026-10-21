import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

@Suite("50. CI Mode & Report Integrity Tests")
@MainActor
struct CIModeTests {

    @Test("Three distinct modes exist and only LIVE_HUMAN_APPROVAL is genuine human approval")
    func testModes() {
        let modes: [CLIExecutionMode] = [.liveHumanApproval, .nonLiveTest, .liveAutonomousAfterLogin]
        #expect(Set(modes.map(\.rawValue)).count == 3)
        #expect(modes.filter(\.isGenuineHumanApproval) == [.liveHumanApproval])
        #expect(!CLIExecutionMode.nonLiveTest.isLive)
        #expect(CLIExecutionMode.parse(from: ["--mode=non_live_test"]) == .nonLiveTest)
        #expect(CLIExecutionMode.parse(from: ["--mode=NOPE"]) == nil)
    }

    @Test("CI approval is scripted and never reads or claims a human")
    func testCIApprovalScripted() async throws {
        let h = RunHarness()
        h.begin()
        let s0 = ProductFixtures.observation("ci", [ProductFixtures.dropdown])
        h.controller.recordObservation(s0)
        let p = ActionProposal(scenarioID: h.scenario.id, snapshotID: s0.snapshotID, elementID: "elem_29", expectedRole: "button",
                               expectedIdentifier: "change-language-dropdown-button", toolName: "tap_element", reason: "r")
        _ = h.controller.handleProposal(p)
        // requestSupervisorApproval must not block on stdin in CI (it would hang the test if it did).
        let approved = Engine.requestSupervisorApproval(mode: .nonLiveTest, controller: h.controller, stepLabel: "Step 0")
        #expect(approved)
    }




    @Test("A run history record made from a CI run is not marked human-approved")
    func testHistoryForCIRun() async throws {
        let h = RunHarness()
        _ = await h.fullRun()
        let record = RunHistoryRecord.make(from: try #require(h.controller.activeRunTrace), humanApproved: CLIExecutionMode.nonLiveTest.isGenuineHumanApproval)
        #expect(record.humanApproved == false)
    }
}
