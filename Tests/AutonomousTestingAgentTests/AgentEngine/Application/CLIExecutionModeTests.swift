import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

@Suite("35. CLI Execution Mode Tests")
struct CLIExecutionModeTests {

    @Test("Only LIVE_HUMAN_APPROVAL may claim genuine human-in-the-loop evidence")
    func testOnlyLiveHumanApprovalIsGenuine() {
        #expect(CLIExecutionMode.liveHumanApproval.isGenuineHumanApproval == true)
        #expect(CLIExecutionMode.liveAutonomousAfterLogin.isGenuineHumanApproval == false)
        #expect(CLIExecutionMode.nonLiveTest.isGenuineHumanApproval == false)
    }

    @Test("Only LIVE_HUMAN_APPROVAL may select the live mutation driver")
    func testLiveFlagsMatchModeNames() {
        #expect(CLIExecutionMode.liveHumanApproval.isLive == true)
        #expect(CLIExecutionMode.nonLiveTest.isLive == false)
    }

    @Test("Mode parsing is explicit: no arguments yields nil, not a silent default")
    func testNoModeArgumentYieldsNil() {
        #expect(CLIExecutionMode.parse(from: ["AutonomousTestingAgent"]) == nil)
        #expect(CLIExecutionMode.parse(from: ["AutonomousTestingAgent", "--smoke"]) == nil)
    }

    @Test("Mode parsing recognizes each explicit mode string")
    func testModeParsingRecognizesEachMode() {
        #expect(CLIExecutionMode.parse(from: ["x", "--mode=LIVE_HUMAN_APPROVAL"]) == .liveHumanApproval)
        #expect(CLIExecutionMode.parse(from: ["x", "--mode=LIVE_AUTONOMOUS_AFTER_LOGIN"]) == .liveAutonomousAfterLogin)
        #expect(CLIExecutionMode.parse(from: ["x", "--mode=NON_LIVE_TEST"]) == .nonLiveTest)
        #expect(CLIExecutionMode.parse(from: ["x", "--mode=non_live_test"]) == .nonLiveTest, "Mode parsing should be case-insensitive.")
    }

    @Test("An unrecognized mode string yields nil rather than silently falling back")
    func testUnknownModeYieldsNil() {
        #expect(CLIExecutionMode.parse(from: ["x", "--mode=SOMETHING_ELSE"]) == nil)
    }

    @Test("NON_LIVE_TEST is simulation-only")
    func testAutomatedModeCannotSelectLiveMutation() async {
        let scenario = await ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!
        let controller = await ScenarioExecutionController(catalog: ScenarioCatalog.shared)
        await controller.startScenario(scenario)
        let obs = Observation(
            snapshotID: "snap_cli", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "elem_lang", role: "button", label: "English", identifier: "change-language-dropdown-button", isEnabled: true, isHittable: true)]
        )
        await controller.recordObservation(obs)
        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET", snapshotID: "snap_cli", elementID: "elem_lang",
            expectedRole: "button", expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element", reason: "test"
        )
        guard case .success = await controller.handleProposal(proposal) else {
            Issue.record("Setup failure")
            return
        }

        let approved = await Engine.requestSupervisorApproval(mode: .nonLiveTest, controller: controller, stepLabel: "test step")
        #expect(approved == true)
        #expect(CLIExecutionMode.nonLiveTest.isLive == false)
        let status = await controller.activeApproval?.status
        #expect(status == .approved)
    }
}
