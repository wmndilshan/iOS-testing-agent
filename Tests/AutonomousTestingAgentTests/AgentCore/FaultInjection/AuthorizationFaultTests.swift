import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Category B: AUTHORIZATION FAILURE. `DispatchAuthorizer` is the sole trusted authorization
/// gate exercised here — every test either calls it directly (pure unit tests of the real, unmodified
/// type) or drives a real `ScenarioExecutionController`. Approval state is produced through the test
/// authority; production clients cannot inject or mutate controller approval state.
@Suite("Fault-injection matrix.B Authorization Fault Injection")
@MainActor
struct AuthorizationFaultTests {
    static func obs(snapshotID: String = "snap_1") -> Observation {
        Observation(snapshotID: snapshotID, bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e2", role: "button", label: "First"),
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ])
    }
    static let step = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"))

    static func validApproval(now: Date, snapshotID: String = "snap_1", status: HITLApprovalStatus = .approved, toolName: String? = "tap_element") -> HITLApprovalRequest {
        HITLApprovalRequest(
            actionName: "tap second", toolName: toolName, boundTestCaseID: "T", reason: "r", targetApp: "com.autonomous.agent.fixture",
            snapshotID: snapshotID, arguments: [:],
            targetLocator: TargetElementLocatorDetails(elementID: "e3", role: "button", label: "Second"),
            createdAt: now, expiresAt: now.addingTimeInterval(120))
            .transitionedForTest(to: status, at: now)
    }

    // MARK: - Direct DispatchAuthorizer unit tests (the real, unmodified trusted gate).

    @Test("Expired authorization is rejected, never dispatched")
    func testExpiredAuthorizationRejected() {
        let now = Date()
        let approval = HITLApprovalRequest(actionName: "tap second", toolName: "tap_element", boundTestCaseID: "T", reason: "r",
                                           targetApp: "com.autonomous.agent.fixture", snapshotID: "snap_1", arguments: [:],
                                           targetLocator: TargetElementLocatorDetails(elementID: "e3", role: "button", label: "Second"),
                                           createdAt: now.addingTimeInterval(-200), expiresAt: now.addingTimeInterval(-80))
            .transitionedForTest(to: .expired, at: now)
        let decision = DispatchAuthorizer().authorize(approval: approval, step: Self.step, observation: Self.obs(), now: now)
        guard case .rejected(let rejection) = decision else { Issue.record("expected rejected"); return }
        #expect(rejection.newStatus == .expired)
        if case .actionFailed = rejection.error {} else { Issue.record("expected actionFailed(expired), got \(rejection.error)") }
    }

    @Test("Wrong snapshot binding is rejected as staleSnapshot")
    func testWrongSnapshotBinding() {
        let now = Date()
        let approval = Self.validApproval(now: now, snapshotID: "snap_approved")
        let decision = DispatchAuthorizer().authorize(approval: approval, step: Self.step, observation: Self.obs(snapshotID: "snap_different"), now: now)
        guard case .rejected(let rejection) = decision else { Issue.record("expected rejected"); return }
        guard case .staleSnapshot(let requested, let current) = rejection.error else { Issue.record("expected staleSnapshot, got \(rejection.error)"); return }
        #expect(requested == "snap_approved"); #expect(current == "snap_different")
    }

    @Test("Wrong target binding (approval names an element absent from the current snapshot) is rejected")
    func testWrongTargetBinding() {
        let now = Date()
        let approval = HITLApprovalRequest(actionName: "tap second", toolName: "tap_element", boundTestCaseID: "T", reason: "r",
                                           targetApp: "com.autonomous.agent.fixture", snapshotID: "snap_1", arguments: [:],
                                           targetLocator: TargetElementLocatorDetails(elementID: "e999-does-not-exist", role: "button", label: "Ghost"),
                                           createdAt: now, expiresAt: now.addingTimeInterval(120))
            .transitionedForTest(to: .approved, at: now)
        let decision = DispatchAuthorizer().authorize(approval: approval, step: Self.step, observation: Self.obs(), now: now)
        guard case .rejected(let rejection) = decision else { Issue.record("expected rejected"); return }
        guard case .elementNotFound(let id) = rejection.error else { Issue.record("expected elementNotFound, got \(rejection.error)"); return }
        #expect(id == "e999-does-not-exist")
    }

    @Test("Missing authorization (approval never granted, status still pending) is rejected before dispatch")
    func testMissingAuthorizationStillPending() {
        let now = Date()
        let approval = Self.validApproval(now: now, status: .pending)
        let decision = DispatchAuthorizer().authorize(approval: approval, step: Self.step, observation: Self.obs(), now: now)
        guard case .rejected(let rejection) = decision else { Issue.record("expected rejected"); return }
        #expect(rejection.newStatus == .failed)
    }

    @Test("Approval exists but its status is denied -> rejected, distinguishable from a mere pending/missing case")
    func testApprovalExistsButDenied() {
        let now = Date()
        let approval = Self.validApproval(now: now, status: .denied)
        let decision = DispatchAuthorizer().authorize(approval: approval, step: Self.step, observation: Self.obs(), now: now)
        guard case .rejected(let rejection) = decision else { Issue.record("expected rejected"); return }
        #expect(rejection.newStatus == nil, "a denial is terminal by policy — status must not be silently rewritten")
        if case .actionFailed(let msg) = rejection.error { #expect(msg.contains("denied")) } else { Issue.record("expected actionFailed(denied)") }
    }

    @Test("Authorization exists for a different action (tool mismatch) is rejected")
    func testAuthorizationForDifferentAction() {
        let now = Date()
        let approval = Self.validApproval(now: now, toolName: "type_text")
        let decision = DispatchAuthorizer().authorize(approval: approval, step: Self.step, observation: Self.obs(), now: now)
        guard case .rejected(let rejection) = decision else { Issue.record("expected rejected"); return }
        if case .actionFailed(let msg) = rejection.error { #expect(msg.contains("tool mismatch")) } else { Issue.record("expected actionFailed(tool mismatch), got \(rejection.error)") }
    }

    // MARK: - Through the real controller: forged approval reaching dispatchCurrentStep.

    static func rig(scenarioID: String) -> (FaultInjectingXCTestDriver, ToolRegistry, ScenarioExecutionController) {
        let mock = SimulatedDriver(currentSnapshot: obs())
        let driver = FaultInjectingXCTestDriver(inner: mock)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(
            id: scenarioID, name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
            actionStep: Self.step)])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        return (driver, registry, controller)
    }

    @Test("Missing authorization entirely (no active approval at all) -> dispatch rejected before any driver call, no auto re-authorization")
    func testNoActiveApprovalAtAll() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "AUTH-1")
        #expect(controller.startScenario(id: "AUTH-1"))
        controller.recordObservation(Self.obs())
        // Deliberately never propose/approve: activeApproval stays nil.
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = result else { Issue.record("expected failure with no active approval"); return }
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
        #expect(controller.activeApproval == nil, "no automatic re-authorization may materialize an approval out of nothing")
    }

    @Test("Reused authorization: dispatching an already-succeeded approval a second time is rejected, not re-executed")
    func testReusedAuthorizationRejected() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "AUTH-2")
        #expect(controller.startScenario(id: "AUTH-2"))
        let observation = Self.obs()
        let proposal = ActionProposal(scenarioID: "AUTH-2", snapshotID: observation.snapshotID, elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                       toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        controller.recordObservation(observation)
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected proposal accepted"); return }
        controller.approveCurrentStep(source: .testAuthority)
        let firstDispatch = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .success = firstDispatch else { Issue.record("expected first dispatch to succeed, got \(firstDispatch)"); return }
        #expect(controller.activeApproval?.status == .succeeded)
        let mutationCountAfterFirst = await driver.mutationCallCount
        #expect(mutationCountAfterFirst == 1, "exactly one real mutation for the first, legitimate dispatch")

        // Attempt to dispatch the SAME (now-succeeded) approval again, without a new proposal/approval cycle.
        let secondDispatch = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = secondDispatch else { Issue.record("a succeeded approval must never be re-dispatched, got \(secondDispatch)"); return }
        let mutationCountAfterSecond = await driver.mutationCallCount
        #expect(mutationCountAfterSecond == 1, "the reused authorization attempt must not add a second real mutation")
    }
}
