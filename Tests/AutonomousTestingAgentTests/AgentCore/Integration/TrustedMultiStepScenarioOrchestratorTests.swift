import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("9. Trusted Multi-Step Scenario Orchestrator Tests")
struct TrustedMultiStepScenarioOrchestratorTests {

    @MainActor
    private func makeBaselineSetup(
        snapshotID: String = "snap_baseline_multi",
        testClock: TestClock = TestClock()
    ) async -> (ScenarioExecutionController, SimulatedDriver, ToolRegistry, Observation) {
        let obs = Observation(
            snapshotID: snapshotID,
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
        let driver = SimulatedDriver(currentSnapshot: obs)
        await driver.setSnapshot(obs)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let toolRegistry = ToolRegistry(projectRoot: root, simulatorDestinationID: "0F0D6B41-9DCA-4D12-A077-F3543AA154F9", driver: driver)
        let controller = ScenarioExecutionController(clock: testClock)
        controller.startScenario(id: "SCENARIO-LANG-SHEET")
        controller.recordObservation(obs)
        return (controller, driver, toolRegistry, obs)
    }

    // A. Step skipping: LLM proposes future step
    @Test @MainActor func testStepSkippingRejected() async throws {
        let (controller, driver, _, obs) = await makeBaselineSetup()
        #expect(controller.currentStepIndex == 0)

        // Proposal targets Step 1 (teardown) while controller is on Step 0
        let skipProposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "close_var_1",
            expectedRole: "button",
            expectedIdentifier: "close_var_1",
            toolName: "tap_element",
            arguments: [:],
            reason: "Attempt to skip to step 1",
            stepIndex: 1
        )
        let res = controller.handleProposal(skipProposal)
        #expect(!res.isSuccess)
        #expect(controller.currentStepIndex == 0, "Step index must remain at 0.")
        #expect(controller.activeApproval == nil, "No approval may be issued for skipped step.")
        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0, "Driver must not be invoked.")
    }

    // B. Step replay: LLM proposes an already-completed step
    @Test @MainActor func testStepReplayRejected() async throws {
        let (controller, driver, toolRegistry, obs) = await makeBaselineSetup()

        // Step 0: Open sheet
        let step0Prop = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Step 0 valid proposal",
            stepIndex: 0
        )
        _ = controller.handleProposal(step0Prop)
        controller.approveCurrentStep(source: .testAuthority)
        let step0Result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(step0Result.isSuccess)
        #expect(controller.currentStepIndex == 1, "Controller must advance to Step 1.")

        // Now attempt to replay Step 0 while at Step 1
        let replayProp = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: controller.activeObservation?.snapshotID ?? "snap_fresh",
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Replay Step 0",
            stepIndex: 0
        )
        let replayRes = controller.handleProposal(replayProp)
        #expect(!replayRes.isSuccess, "Replaying already-completed step must be rejected.")
        #expect(controller.currentStepIndex == 1, "Step index must remain at 1.")
    }

    // C. Step ordering manipulation: LLM attempts to modify step index
    @Test @MainActor func testStepOrderingManipulationRejected() async throws {
        let (controller, driver, _, obs) = await makeBaselineSetup()

        let hackedProposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Hacked step index",
            stepIndex: 99
        )
        let res = controller.handleProposal(hackedProposal)
        #expect(!res.isSuccess)
        #expect(controller.currentStepIndex == 0)
        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0)
    }



    // F. Cancellation during approval
    @Test @MainActor func testCancellationDuringApproval() async throws {
        let (controller, driver, _, obs) = await makeBaselineSetup()

        let prop = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Valid proposal"
        )
        _ = controller.handleProposal(prop)
        #expect(controller.scenarioLifecycle == .awaitingApproval)
        #expect(controller.activeApproval?.status == .pending)

        // Cancel while approval is pending
        controller.cancel(reason: "Supervisor cancelled run.")
        #expect(controller.scenarioLifecycle == .cancelled)
        #expect(controller.activeApproval == nil, "Pending approval must be invalidated upon cancellation.")

        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0)
    }

    // G. Cancellation before execution
    @Test @MainActor func testCancellationBeforeExecution() async throws {
        let (controller, driver, toolRegistry, obs) = await makeBaselineSetup()

        let prop = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Approved proposal"
        )
        _ = controller.handleProposal(prop)
        controller.approveCurrentStep(source: .testAuthority)

        // Cancel before dispatch
        controller.cancel(reason: "Emergency halt.")
        #expect(controller.scenarioLifecycle == .cancelled)

        let dispatchResult = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!dispatchResult.isSuccess)
        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0, "Driver must not be dispatched when cancelled.")
    }

    // H. Timeout via TestClock
    @Test @MainActor func testScenarioTimeoutViaTestClock() async throws {
        let testClock = TestClock()
        let (controller, driver, toolRegistry, obs) = await makeBaselineSetup(testClock: testClock)
        controller.scenarioTimeoutSeconds = 60.0

        let prop = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Proposal before timeout"
        )
        _ = controller.handleProposal(prop)
        controller.approveCurrentStep(source: .testAuthority)

        // Advance clock past 60s timeout
        testClock.advance(by: 65)

        let dispatchResult = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!dispatchResult.isSuccess)
        #expect(controller.scenarioLifecycle == .blocked, "Timeout must transition scenario to .blocked.")
        let tapCount = await driver.invokedActionCount["tap"] ?? 0
        #expect(tapCount == 0, "Driver must not be dispatched when timed out.")
    }

    // I. Illegal lifecycle transition: Attempt completed -> executing
    @Test @MainActor func testIllegalTransitionFromCompletedRejected() async throws {
        let (controller, driver, toolRegistry, obs) = await makeBaselineSetup()

        // Execute Step 0
        let prop0 = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Step 0"
        )
        _ = controller.handleProposal(prop0)
        controller.approveCurrentStep(source: .testAuthority)
        _ = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)

        // Execute Step 1
        let modalSnap = try #require(controller.activeObservation)
        let closeElem = modalSnap.elements.first(where: { $0.identifier == "close_var_1" || $0.label == "close_var_1" })
        let closeID = try #require(closeElem?.id)
        let prop1 = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: modalSnap.snapshotID,
            elementID: closeID,
            expectedRole: "button",
            expectedIdentifier: "close_var_1",
            toolName: "tap_element",
            arguments: [:],
            reason: "Step 1",
            stepIndex: 1
        )
        _ = controller.handleProposal(prop1)
        controller.approveCurrentStep(source: .testAuthority)
        _ = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)

        #expect(controller.isCompleted)

        // Attempting to dispatch again while completed
        let illegalDispatch = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!illegalDispatch.isSuccess)
    }

    // J. Verification failure recovery
    @Test @MainActor func testVerificationFailureRecoveryRequiresFullNewLifecycle() async throws {
        let (controller, driver, toolRegistry, obs) = await makeBaselineSetup()

        // Queue bad post observation
        let badPost = Observation(
            snapshotID: "snap_bad_j",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: []
        )
        await driver.queueNextSnapshot(badPost)

        let prop = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "First attempt"
        )
        _ = controller.handleProposal(prop)
        controller.approveCurrentStep(source: .testAuthority)
        let firstRun = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        let firstVerif = try #require(try? firstRun.get())
        #expect(!firstVerif.verified)
        #expect(controller.scenarioLifecycle == .failed)

        // Attempting to re-dispatch without new proposal fails closed
        let directRetry = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!directRetry.isSuccess)

        // Proper recovery: Fresh observation + New proposal + Human approval
        let goodFreshObs = Observation(
            snapshotID: "snap_recovered_j",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "change-language-dropdown-button", role: "button", label: "English", identifier: "change-language-dropdown-button", isEnabled: true, isHittable: true)
            ]
        )
        await driver.setSnapshot(goodFreshObs)
        controller.recordObservation(goodFreshObs)

        let retryProp = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: goodFreshObs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: ["attempt": .int(2)],
            reason: "Recovered proposal"
        )
        let handleRetry = controller.handleProposal(retryProp)
        #expect(handleRetry.isSuccess)
        controller.approveCurrentStep(source: .testAuthority)

        let recoveredRun = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        let recoveredVerif = try #require(try? recoveredRun.get())
        #expect(recoveredVerif.verified)
        #expect(controller.currentStepIndex == 1)
    }

    // K. Multi-step completion
    @Test @MainActor func testMultiStepScenarioCompletion() async throws {
        let (controller, driver, toolRegistry, obs) = await makeBaselineSetup()

        // Step 0: Open sheet
        let prop0 = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Open sheet",
            stepIndex: 0
        )
        _ = controller.handleProposal(prop0)
        controller.approveCurrentStep(source: .testAuthority)
        let res0 = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        let verif0 = try #require(try? res0.get())
        #expect(verif0.verified)
        #expect(controller.completedStepCount == 1)
        #expect(controller.currentStepIndex == 1)

        // Step 1: Dismiss sheet (Teardown)
        let modalSnap = try #require(controller.activeObservation)
        let closeElem = modalSnap.elements.first(where: { $0.identifier == "close_var_1" || $0.label == "close_var_1" })
        let closeID = try #require(closeElem?.id)
        let prop1 = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: modalSnap.snapshotID,
            elementID: closeID,
            expectedRole: "button",
            expectedIdentifier: "close_var_1",
            toolName: "tap_element",
            arguments: [:],
            reason: "Dismiss sheet",
            stepIndex: 1
        )
        _ = controller.handleProposal(prop1)
        controller.approveCurrentStep(source: .testAuthority)
        let res1 = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        let verif1 = try #require(try? res1.get())
        #expect(verif1.verified)
        #expect(controller.completedStepCount == 2)
        #expect(controller.isCompleted, "Scenario must reach .completed when all steps pass.")
    }

    // L. Missing teardown
    @Test @MainActor func testMissingTeardownLeavesScenarioIncomplete() async throws {
        let (controller, driver, toolRegistry, obs) = await makeBaselineSetup()

        // Execute only Step 0
        let prop0 = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Step 0 only"
        )
        _ = controller.handleProposal(prop0)
        controller.approveCurrentStep(source: .testAuthority)
        _ = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)

        #expect(controller.completedStepCount == 1)
        #expect(!controller.isCompleted, "Scenario cannot be completed without executing required teardown.")
        #expect(controller.scenarioLifecycle == .observing)
    }

    // M. Concurrent step advancement
    @Test @MainActor func testConcurrentStepAdvancementSerialized() async throws {
        let (controller, driver, toolRegistry, obs) = await makeBaselineSetup()

        let prop = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: obs.snapshotID,
            elementID: "change-language-dropdown-button",
            expectedRole: "button",
            expectedIdentifier: "change-language-dropdown-button",
            toolName: "tap_element",
            arguments: [:],
            reason: "Concurrent test"
        )
        _ = controller.handleProposal(prop)
        controller.approveCurrentStep(source: .testAuthority)

        // Lock execution flag to simulate in-flight execution
        controller.isExecutingStep = true

        let concurrentAttempt = await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry)
        #expect(!concurrentAttempt.isSuccess)
        #expect(controller.completedStepCount == 0, "Concurrent attempt must not increment step count.")
    }
}

// MARK: - 10. Required Tests: Live Integration Security Boundary Tests A-H (Section 18)
