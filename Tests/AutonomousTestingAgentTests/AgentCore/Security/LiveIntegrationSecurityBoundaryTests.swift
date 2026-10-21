import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("10. Live Integration Security Boundary Tests A-H")
struct LiveIntegrationSecurityBoundaryTests {

    @MainActor
    private func makeSetup() async -> (ScenarioExecutionController, SimulatedDriver, ToolRegistry, Observation) {
        let clock = TestClock()
        let driver = SimulatedDriver()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let toolRegistry = ToolRegistry(projectRoot: root, simulatorDestinationID: "0F0D6B41-9DCA-4D12-A077-F3543AA154F9", driver: driver)
        let controller = ScenarioExecutionController(clock: clock)
        controller.startScenario(id: "SCENARIO-LANG-SHEET")

        let obs = Observation(
            snapshotID: "snap_sec_001",
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
                ),
                UIElementSnapshot(
                    id: "close_var_1",
                    role: "button",
                    label: "close_var_1",
                    identifier: "close_var_1",
                    isEnabled: true,
                    isHittable: true
                )
            ]
        )
        controller.recordObservation(obs)
        await driver.setSnapshot(obs)
        return (controller, driver, toolRegistry, obs)
    }


    // Test B — Invalid LLM action
    // Real or recorded invalid LLM response: driverInvoked = false
    @Test @MainActor func testB_InvalidLLMActionDoesNotInvokeDriver() async throws {
        let (controller, driver, toolRegistry, obs) = await makeSetup()

        // Invalid proposal targeting an unknown element not present in catalog step or observation
        let invalidProposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "non_existent_unauthorized_button",
            expectedRole: "button",
            toolName: "tap_element",
            reason: "Untrusted invalid proposal"
        )

        let handleResult = controller.handleProposal(invalidProposal)
        #expect(!handleResult.isSuccess, "Test B: Invalid LLM proposal must be rejected by trusted validator.")
        #expect(controller.activeApproval == nil)

        // Attempting to dispatch when no approval exists must fail closed
        let dispatchResult = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!dispatchResult.isSuccess)
        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0, "Test B: Driver must NOT be invoked for invalid LLM proposal.")
    }



    // Test E — Stale snapshot
    // Old proposal after a new observation: rejected, driverInvoked = false
    @Test @MainActor func testE_StaleSnapshotRejected() async throws {
        let (controller, driver, toolRegistry, obs) = await makeSetup()

        let validProposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            reason: "Valid proposal for initial snapshot"
        )
        _ = controller.handleProposal(validProposal)
        controller.approveCurrentStep(source: .testAuthority)

        // New observation arrives BEFORE dispatch
        let freshObs = Observation(
            snapshotID: "snap_sec_fresh_002",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: obs.elements
        )
        controller.recordObservation(freshObs)
        await driver.setSnapshot(freshObs)

        // Attempting dispatch must fail closed due to stale snapshot
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!result.isSuccess, "Test E: Stale snapshot must reject dispatch.")
        if case .failure(let err) = result {
            if case .staleSnapshot = err {
                // Expected
            } else {
                Issue.record("Expected staleSnapshot error, received: \(err)")
            }
        }
        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0, "Test E: Driver must NOT be invoked on stale snapshot.")
    }

    // Test F — Duplicate proposal
    // Repeated valid proposal: rejected
    @Test @MainActor func testF_DuplicateProposalRejected() async throws {
        let (controller, driver, _, obs) = await makeSetup()

        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            reason: "Initial valid proposal"
        )

        let first = controller.handleProposal(proposal)
        #expect(first.isSuccess)

        // Identical proposal submitted while first is pending
        let second = controller.handleProposal(proposal)
        #expect(!second.isSuccess, "Test F: Duplicate proposal must be rejected.")
        if case .failure(let err) = second {
            if case .duplicateProposal = err {
                // Expected
            } else {
                Issue.record("Expected duplicateProposal error, got: \(err)")
            }
        }

        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0)
    }

    // Test G — Consumed token
    // Second dispatch: rejected, driverInvoked = false
    @Test @MainActor func testG_ConsumedTokenCannotExecuteTwice() async throws {
        let (controller, driver, toolRegistry, obs) = await makeSetup()

        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            reason: "Dispatch token test"
        )
        _ = controller.handleProposal(proposal)
        controller.approveCurrentStep(source: .testAuthority)

        // First dispatch succeeds by queueing post observation with close_var_1
        let postObs = Observation(
            snapshotID: "snap_sec_step0_post",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "close_var_1", role: "button", label: "close_var_1", identifier: "close_var_1", isEnabled: true, isHittable: true)
            ]
        )
        await driver.queueNextSnapshot(postObs)

        let firstDispatch = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(firstDispatch.isSuccess)
        let initialTapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(initialTapCount == 1)

        // Attempting second dispatch with consumed token must fail
        let secondDispatch = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!secondDispatch.isSuccess, "Test G: Consumed token must be rejected on second dispatch.")
        let finalTapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(finalTapCount == 1, "Test G: Driver must NOT be invoked twice.")
    }

    // Test H — Human approval required
    // A valid LLM proposal must not execute until explicit SwiftUI approval occurs.
    @Test @MainActor func testH_HumanApprovalRequiredBeforeExecution() async throws {
        let (controller, driver, toolRegistry, obs) = await makeSetup()

        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            reason: "Awaiting supervisor authorization"
        )

        let handleResult = controller.handleProposal(proposal)
        #expect(handleResult.isSuccess)
        #expect(controller.activeApproval?.status == .pending)

        // Attempting to dispatch WITHOUT calling approveCurrentStep(source: .testAuthority)
        let prematureDispatch = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!prematureDispatch.isSuccess, "Test H: Execution without explicit approval must be blocked.")
        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0, "Test H: Driver must NOT be invoked without human approval.")
        #expect(controller.activeApproval?.status == .failed)
        #expect(controller.activeApproval?.driverInvoked == false)
    }
}

// MARK: - 11. Level 10 Hardening & Security Regression Tests
