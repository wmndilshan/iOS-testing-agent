import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("33. Inspector Safety Control Enforcement Tests")
@MainActor
struct InspectorSafetyControlEnforcementTests {

    @Test("isPaused blocks handleProposal from accepting any new proposal")
    func testPausedControllerRejectsProposals() {
        let scenario = ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!
        let controller = ScenarioExecutionController(catalog: ScenarioCatalog.shared)
        controller.startScenario(scenario)
        controller.recordObservation(Observation(
            snapshotID: "snap_p", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "elem_lang", role: "button", label: "English", identifier: "change-language-dropdown-button", isEnabled: true, isHittable: true)]
        ))
        controller.isPaused = true

        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET", snapshotID: "snap_p", elementID: "elem_lang",
            expectedRole: "button", expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element", reason: "test"
        )
        let result = controller.handleProposal(proposal)
        switch result {
        case .success:
            Issue.record("Security violation: a paused controller accepted a new proposal.")
        case .failure(let err):
            #expect(err.localizedDescription.lowercased().contains("pause"))
        }
    }

    @Test("isPaused blocks dispatchCurrentStep even with a valid pre-existing approval")
    func testPausedControllerBlocksDispatch() async throws {
        let scenario = ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!
        let controller = ScenarioExecutionController(catalog: ScenarioCatalog.shared)
        controller.startScenario(scenario)
        let obs = Observation(
            snapshotID: "snap_p2", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "elem_lang", role: "button", label: "English", identifier: "change-language-dropdown-button", isEnabled: true, isHittable: true)]
        )
        controller.recordObservation(obs)
        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET", snapshotID: "snap_p2", elementID: "elem_lang",
            expectedRole: "button", expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element", reason: "test"
        )
        guard case .success = controller.handleProposal(proposal) else {
            Issue.record("Setup failure: proposal was rejected")
            return
        }
        controller.approveCurrentStep(source: .testAuthority)
        #expect(controller.activeApproval?.status == .approved)

        // Pause AFTER approval — dispatch must still be blocked.
        controller.isPaused = true

        let mockDriver = SimulatedDriver(currentSnapshot: obs)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: mockDriver)
        let result = await controller.dispatchCurrentStep(driver: mockDriver, toolRegistry: registry)
        switch result {
        case .success:
            Issue.record("Security violation: dispatch proceeded while paused.")
        case .failure(let err):
            #expect(err.localizedDescription.lowercased().contains("pause"))
        }
        let tapCount = await mockDriver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0, "The driver must never be invoked while the controller is paused.")
    }
}

