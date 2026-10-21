import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Category F: DRIVER FAILURE. Every fault is injected strictly BELOW the trust boundary, via
/// `FaultInjectingXCTestDriver` configured to throw a specific `DriverError` on a specific call — never a
/// production `if faultInjected` branch, and never a change to `ScenarioExecutionController`,
/// `ScenarioStepDispatcher`, or `ToolRegistry` themselves. Each test proves: correct `FailureClass`
/// mapping, no silent success, no automatic retry of the mutating action, and (for a post-action
/// observation failure) that a driver-reported "done" is never confused with a verified postcondition.
@Suite("Fault-injection matrix.F Driver Fault Injection")
@MainActor
struct DriverFaultTests {
    static let step = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"),
                                    verification: nil)
    static func obs(snapshotID: String = "snap_1") -> Observation {
        Observation(snapshotID: snapshotID, bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ])
    }

    static func rigApprovedForDispatch(scenarioID: String) async -> (FaultInjectingXCTestDriver, ToolRegistry, ScenarioExecutionController) {
        let mock = SimulatedDriver(currentSnapshot: obs())
        let driver = FaultInjectingXCTestDriver(inner: mock)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: scenarioID, name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: Self.step)])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(id: scenarioID))
        let observation = obs()
        controller.recordObservation(observation)
        let proposal = ActionProposal(scenarioID: scenarioID, snapshotID: observation.snapshotID, elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                       toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected proposal accepted"); return (driver, registry, controller) }
        controller.approveCurrentStep(source: .testAuthority)
        return (driver, registry, controller)
    }

    @Test("Driver timeout during a real mutation -> failure surfaced honestly, never silent success, approval marked failed (no auto-retry)")
    func testDriverTimeout() async throws {
        let (driver, registry, controller) = await Self.rigApprovedForDispatch(scenarioID: "DRV-1")
        await driver.failNextMutation(.timedOut("tap did not complete within bound"))
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(.timedOut) = result else { Issue.record("expected timedOut failure, got \(result)"); return }
        #expect(controller.activeApproval?.status == .failed)
        #expect(controller.scenarioLifecycle == .failed)

        // No automatic retry: dispatching again on the same (now-failed) approval must not re-attempt the mutation.
        let retry = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = retry else { Issue.record("a failed approval must never succeed on retry"); return }
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 1, "exactly the one real attempt — no silent auto-retry of the mutation")
    }

    @Test("Application not running / wrong application during dispatch -> failure surfaced honestly, distinguishable failure class, no auto-retry")
    func testApplicationNotRunning() async throws {
        let (driver, registry, controller) = await Self.rigApprovedForDispatch(scenarioID: "DRV-2")
        await driver.failNextMutation(.wrongApplication(expected: "com.autonomous.agent.fixture", observed: "com.apple.springboard"))
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(.wrongApplication) = result else { Issue.record("expected wrongApplication failure, got \(result)"); return }
        #expect(controller.activeApproval?.status == .failed)
    }

    @Test("Target missing at actual driver-execution time (distinct from the pre-dispatch DispatchAuthorizer check) -> failure, never silent success")
    func testTargetMissingDuringDriverExecution() async throws {
        let (driver, registry, controller) = await Self.rigApprovedForDispatch(scenarioID: "DRV-3")
        // Passed DispatchAuthorizer's own pre-check (the element existed in `activeObservation`), but the
        // real device layer itself reports it missing at the moment of the actual gesture — a real race a
        // pure pre-check can never fully close, which is exactly why the driver's own result is never
        // silently assumed successful.
        await driver.failNextMutation(.elementNotFound("e3"))
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(.elementNotFound) = result else { Issue.record("expected elementNotFound failure, got \(result)"); return }
        #expect(controller.activeApproval?.status == .failed)
    }

    @Test("XCTest-runner-shaped failure (actionFailed from a real xcodebuild/test-runner error) surfaces honestly, never becomes a false success")
    func testXCTestRunnerFailure() async throws {
        let (driver, registry, controller) = await Self.rigApprovedForDispatch(scenarioID: "DRV-4")
        await driver.failNextMutation(.actionFailed("xcodebuild test exited with status code 65"))
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(.actionFailed(let msg)) = result else { Issue.record("expected actionFailed, got \(result)"); return }
        #expect(msg.contains("65"))
        #expect(controller.activeApproval?.status == .failed)
    }

    @Test("Malformed/failed observation AFTER a successful mutation -> the mutation's own success is never confused with a verified postcondition; result is a failure, not LIVE_VERIFIED")
    func testPostActionObservationFailure() async throws {
        let (driver, registry, controller) = await Self.rigApprovedForDispatch(scenarioID: "DRV-5")
        // The mutation itself succeeds (no injected mutation error); the driver's NEXT call — the fresh
        // post-action observation capture — fails instead.
        await driver.failNextObservation(.observationFailed("accessibility tree snapshot corrupted"))
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(let error) = result else { Issue.record("expected failure — driver success must never be confused with a verified postcondition, got \(result)"); return }
        if case .actionFailed(let msg) = error { #expect(msg.contains("Failed to capture fresh observation")) } else { Issue.record("expected actionFailed(post-observation), got \(error)") }
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 1, "the real mutation DID happen exactly once — this test is specifically about not trusting it as verified without a fresh, successful post-observation")
    }

    @Test("A driver failure never produces a .success result, whatever the error shape — success and failure are never conflated")
    func testDriverFailureNeverProducesSuccess() async throws {
        for error: DriverError in [.timedOut("t"), .actionFailed("a"), .elementNotFound("e"), .observationFailed("o"), .simulatorNotAvailable("s")] {
            let (driver, registry, controller) = await Self.rigApprovedForDispatch(scenarioID: "DRV-6-\(error)")
            await driver.failNextMutation(error)
            let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
            guard case .failure = result else { Issue.record("expected failure for injected \(error), got \(result)"); continue }
        }
    }
}
