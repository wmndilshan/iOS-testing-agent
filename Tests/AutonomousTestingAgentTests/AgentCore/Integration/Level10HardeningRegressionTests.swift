import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("11. Level 10 Hardening & Security Regression Tests")
struct Level10HardeningRegressionTests {

    @Test @MainActor func testProposalArgumentsCannotOverrideTrustedFields() async throws {
        let clock = TestClock()
        let controller = ScenarioExecutionController(clock: clock)
        controller.startScenario(id: "SCENARIO-LANG-SHEET")

        let obs = Observation(
            snapshotID: "snap_tamper_1",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(
                    id: "change-language-dropdown-button",
                    role: "button",
                    label: "English",
                    identifier: "change-language-dropdown-button",
                    isEnabled: true,
                    isHittable: true
                )
            ]
        )
        controller.recordObservation(obs)

        // Attempt to tamper with trusted parameters via arguments
        let maliciousProposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: "snap_tamper_1",
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [
                "snapshotID": .string("attacker_fake_snapshot"),
                "elementID": .string("attacker_fake_element"),
                "toolName": .string("rm_rf")
            ],
            reason: "Malicious argument injection"
        )

        let result = controller.handleProposal(maliciousProposal)
        switch result {
        case .success:
            Issue.record("Proposal with tampered trusted arguments must be rejected.")
        case .failure(let error):
            guard case .validationFailed(let reason) = error else {
                Issue.record("Expected validationFailed error, got: \(error)")
                return
            }
            #expect(reason.contains("Security boundary violation"))
            #expect(controller.scenarioLifecycle == .failed)
        }
    }

    @Test @MainActor func testMutatingActionWithoutVerificationFailsClosed() async throws {
        let clock = TestClock()
        let unverifiedScenario = SafeScenario(
            id: "SCENARIO-UNVERIFIED-MUTATION",
            name: "Unverified Mutation Scenario",
            purpose: "Verify fail-closed behavior when catalog step lacks verification",
            initialStateRequirement: "Any",
            expectedPostActionState: "Any",
            changesUIState: true,
            actionStep: ScenarioStep(
                id: "step_unverified",
                name: "Unverified Mutating Action",
                description: "Action without verification rule",
                toolName: "tap_element",
                locator: ScenarioLocator(role: "button", identifier: "btn_target", label: "Target"),
                requiresApproval: true,
                verification: nil
            ),
            teardownStep: nil
        )

        let catalog = ScenarioCatalog(scenarios: [unverifiedScenario])
        let validator = TrustedActionValidator(catalog: catalog)
        let controller = ScenarioExecutionController(catalog: catalog, validator: validator, clock: clock)
        controller.startScenario(unverifiedScenario)

        let obs = Observation(
            snapshotID: "snap_unverif_1",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "btn_target", role: "button", label: "Target", identifier: "btn_target", isEnabled: true, isHittable: true)
            ]
        )
        controller.recordObservation(obs)

        let proposal = ActionProposal(
            scenarioID: "SCENARIO-UNVERIFIED-MUTATION",
            snapshotID: "snap_unverif_1",
            elementID: "btn_target",
            expectedRole: "button",
            expectedIdentifier: "btn_target",
            toolName: "tap_element",
            reason: "Valid proposal for unverified step"
        )

        let propRes = controller.handleProposal(proposal)
        #expect(propRes.isSuccess)
        controller.bindPendingExecutionContext(executionID: "unverified", simulatorUDID: "test_sim")
        controller.approveCurrentStep(source: .testAuthority)

        let mockDriver = SimulatedDriver()
        await mockDriver.setSnapshot(obs)
        let toolRegistry = ToolRegistry(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            simulatorDestinationID: "test_sim",
            driver: mockDriver
        )

        let dispatchRes = await controller.dispatchCurrentStep(driver: mockDriver, toolRegistry: toolRegistry)
        switch dispatchRes {
        case .success(let verResult):
            #expect(verResult.verified == false, "Mutating step lacking verification rule must fail closed.")
            #expect(verResult.reason.contains("Fail-Closed Verification"))
        case .failure:
            Issue.record("Dispatch should return verification failure result, not throw.")
        }
    }

    @Test @MainActor func testTOCTOUElementDisappearanceFailsClosed() async throws {
        let clock = TestClock()
        let controller = ScenarioExecutionController(clock: clock)
        controller.startScenario(id: "SCENARIO-LANG-SHEET")

        let initialObs = Observation(
            snapshotID: "snap_toctou_init",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(
                    id: "change-language-dropdown-button",
                    role: "button",
                    label: "English",
                    identifier: "change-language-dropdown-button",
                    isEnabled: true,
                    isHittable: true
                )
            ]
        )
        controller.recordObservation(initialObs)

        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: "snap_toctou_init",
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            reason: "Valid proposal before TOCTOU disappearance"
        )
        let propRes = controller.handleProposal(proposal)
        #expect(propRes.isSuccess)
        controller.bindPendingExecutionContext(executionID: "toctou", simulatorUDID: "test_sim")
        controller.approveCurrentStep(source: .testAuthority)

        // Simulate UI element disappearing right before dispatch
        let changedObs = Observation(
            snapshotID: "snap_toctou_init",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [] // Element disappeared!
        )
        controller.activeObservation = changedObs

        let mockDriver = SimulatedDriver()
        await mockDriver.setSnapshot(changedObs)
        let toolRegistry = ToolRegistry(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            simulatorDestinationID: "test_sim",
            driver: mockDriver
        )

        let dispatchRes = await controller.dispatchCurrentStep(driver: mockDriver, toolRegistry: toolRegistry)
        switch dispatchRes {
        case .success:
            Issue.record("Dispatch must fail closed when target element has disappeared.")
        case .failure(let err):
            #expect(err == .elementNotFound("change-language-dropdown-button"))
        }

        let tapCount = await mockDriver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0, "Driver must NOT be invoked when element disappeared before dispatch.")
    }

    @Test func testPlaceholderAPIKeysRejected() {
        #expect(Configuration.isPlaceholderKey("your_api_key_here") == true)
        #expect(Configuration.isPlaceholderKey("placeholder") == true)
        #expect(Configuration.isPlaceholderKey("local_dev") == true)
        #expect(Configuration.isPlaceholderKey("dummy") == true)
        #expect(Configuration.isPlaceholderKey("changeme") == true)
        #expect(Configuration.isPlaceholderKey("   ") == true)
        #expect(Configuration.isPlaceholderKey("") == true)
        #expect(Configuration.isPlaceholderKey("AIzaSyD-ValidLookingKey12345") == false)
    }
}
