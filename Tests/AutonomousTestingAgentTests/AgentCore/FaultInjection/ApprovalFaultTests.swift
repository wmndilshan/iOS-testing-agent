import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Category C: HITL / APPROVAL FAILURE. Every test drives the real
/// `ScenarioExecutionController` lifecycle (`startScenario` / `handleProposal` / `approveCurrentStep` /
/// `denyCurrentStep` / `dispatchCurrentStep` / `cancel` / `reset`) with a real `TestClock` where TTL
/// matters — never a fake/short-circuited approval path.
@Suite("Fault-injection matrix.C HITL / Approval Fault Injection")
@MainActor
struct ApprovalFaultTests {
    static let step = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"))
    static func obs(snapshotID: String = "snap_1") -> Observation {
        Observation(snapshotID: snapshotID, bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e2", role: "button", label: "First"),
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ])
    }

    static func rig(scenarioID: String, clock: TestClock = TestClock()) -> (FaultInjectingXCTestDriver, ToolRegistry, ScenarioExecutionController) {
        let mock = SimulatedDriver(currentSnapshot: obs())
        let driver = FaultInjectingXCTestDriver(inner: mock)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(
            id: scenarioID, name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: Self.step)])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        controller.clock = clock
        return (driver, registry, controller)
    }

    static func proposeStep(_ controller: ScenarioExecutionController, scenarioID: String, snapshot: Observation) {
        controller.recordObservation(snapshot)
        let proposal = ActionProposal(scenarioID: scenarioID, snapshotID: snapshot.snapshotID, elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                       toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected proposal accepted") ; return }
    }

    @Test("Approval denied by supervisor -> action never executes, no ToolRegistry mutation, downstream never reached")
    func testApprovalDenied() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "APR-1")
        #expect(controller.startScenario(id: "APR-1"))
        Self.proposeStep(controller, scenarioID: "APR-1", snapshot: Self.obs())
        controller.denyCurrentStep(reason: "test denial")
        #expect(controller.activeApproval?.status == .denied)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = result else { Issue.record("expected failure after denial"); return }
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0, "a denied action must never reach the driver")
        #expect(controller.currentStepIndex == 0, "the step index must not advance past a denied step")
    }

    @Test("Approval expires (real TTL, real clock advance) before it is even approved -> auto-expired, never approvable, never dispatched")
    func testApprovalExpiresBeforeApproval() async throws {
        let clock = TestClock()
        let (driver, registry, controller) = Self.rig(scenarioID: "APR-2", clock: clock)
        // Isolate the 120s single-use TOKEN TTL from the (also 120s-default) overall SCENARIO timeout, so
        // this test exercises exactly the approval-token expiry path in `approveCurrentStep`, not the
        // broader scenario-timeout guard that runs first and would otherwise short-circuit it — both are
        // real, both fail closed, but this test is specifically about the token TTL.
        controller.scenarioTimeoutSeconds = 3600
        #expect(controller.startScenario(id: "APR-2"))
        Self.proposeStep(controller, scenarioID: "APR-2", snapshot: Self.obs())
        #expect(controller.activeApproval?.status == .pending)
        clock.advance(by: ApprovalPolicy.tokenTimeToLive + 5) // real 120s TTL, real advance past it
        controller.approveCurrentStep(source: .testAuthority)
        #expect(controller.activeApproval?.status == .expired, "approveCurrentStep must itself refuse to approve a request whose TTL has elapsed")
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = result else { Issue.record("expected failure on an expired approval"); return }
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
    }

    @Test("Approval expires (real TTL) AFTER being approved but BEFORE dispatch -> dispatch itself refuses, no driver call")
    func testApprovalExpiresAfterApprovalBeforeDispatch() async throws {
        let clock = TestClock()
        let (driver, registry, controller) = Self.rig(scenarioID: "APR-3", clock: clock)
        controller.scenarioTimeoutSeconds = 3600 // isolate token TTL from the overall scenario timeout — see APR-2's note.
        #expect(controller.startScenario(id: "APR-3"))
        Self.proposeStep(controller, scenarioID: "APR-3", snapshot: Self.obs())
        controller.approveCurrentStep(source: .testAuthority)
        #expect(controller.activeApproval?.status == .approved)
        clock.advance(by: ApprovalPolicy.tokenTimeToLive + 5)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = result else { Issue.record("expected failure: approved token elapsed its TTL before dispatch"); return }
        #expect(controller.activeApproval?.status == .expired)
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
    }

    @Test("Approval request lost across a simulated restart (controller.reset) -> dispatch finds no approval, never fabricates one")
    func testApprovalLostOnRestart() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "APR-4")
        #expect(controller.startScenario(id: "APR-4"))
        Self.proposeStep(controller, scenarioID: "APR-4", snapshot: Self.obs())
        controller.approveCurrentStep(source: .testAuthority)
        #expect(controller.activeApproval?.status == .approved)

        // Simulate the approval reference being lost (e.g. process restart, in-memory state gone) — the
        // real `reset()` the controller itself exposes, not a fabricated shortcut.
        controller.reset()
        #expect(controller.activeApproval == nil)

        // Restarting the scenario does not resurrect the old approval.
        #expect(controller.startScenario(id: "APR-4"))
        #expect(controller.activeApproval == nil)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = result else { Issue.record("expected failure with no approval present after restart"); return }
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
    }

    @Test("Approval granted, then the scenario is cancelled before dispatch -> dispatch refuses the cancelled scenario, no driver call")
    func testApprovalAfterScenarioCancellation() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "APR-5")
        #expect(controller.startScenario(id: "APR-5"))
        Self.proposeStep(controller, scenarioID: "APR-5", snapshot: Self.obs())
        controller.approveCurrentStep(source: .testAuthority)
        #expect(controller.activeApproval?.status == .approved)
        controller.cancel(reason: "supervisor cancelled mid-flight")
        #expect(controller.isCancelled)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(let error) = result else { Issue.record("expected failure after cancellation"); return }
        if case .actionFailed(let msg) = error { #expect(msg.lowercased().contains("cancelled")) } else { Issue.record("expected actionFailed(cancelled), got \(error)") }
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
    }

    @Test("An authority-approved request whose target identifier mismatches the observation is rejected")
    func testApprovalForDifferentTargetRejected() {
        let now = Date()
        let approval = HITLApprovalRequest(
            actionName: "tap second", toolName: "tap_element", boundTestCaseID: "APR-6", reason: "r",
            targetApp: "com.autonomous.agent.fixture", snapshotID: "snap_1", arguments: [:],
            targetLocator: TargetElementLocatorDetails(elementID: "e3", role: "button", identifier: "fixture.tabs.thirdButton.forged"),
            createdAt: now, expiresAt: now.addingTimeInterval(120)
        ).transitionedForTest(to: .approved, at: now)
        let decision = DispatchAuthorizer().authorize(approval: approval, step: Self.step, observation: Self.obs(), now: now)
        guard case .rejected(let rejection) = decision else { Issue.record("expected rejection"); return }
        if case .actionFailed(let message) = rejection.error {
            #expect(message.contains("identifier changed"))
        } else {
            Issue.record("expected identifier-mismatch actionFailed")
        }
    }
}
