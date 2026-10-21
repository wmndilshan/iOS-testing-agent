import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Category A: STALE OBSERVATION. Every test here injects a fault entirely through real
/// sequencing of the EXISTING trusted spine (`ScenarioExecutionController.recordObservation` /
/// `handleProposal` / `approveCurrentStep` / `dispatchCurrentStep`, and `DispatchAuthorizer` itself) —
/// nothing here is a stub or a bypass; `DispatchAuthorizer.authorize` is the real, unmodified trusted
/// gate at every assertion.
@Suite("Fault-injection matrix.A Stale Observation Fault Injection")
@MainActor
struct StaleObservationFaultTests {
    typealias SequencedObservationDriver = StatefulScenarioExecutionTests.SequencedObservationDriver

    static func tabsObservation(selected: String, snapshotID: String) -> Observation {
        Observation(snapshotID: snapshotID, bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "other", label: "tab:\(selected)", identifier: "fixture.tabs.status"),
            UIElementSnapshot(id: "e2", role: "button", label: "First"),
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ])
    }

    static func rig(scenarioID: String) -> (FaultInjectingXCTestDriver, ToolRegistry, ScenarioExecutionController) {
        let obsA = tabsObservation(selected: "first", snapshotID: "snap_A")
        let mock = SimulatedDriver(currentSnapshot: obsA)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(
            id: scenarioID, name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
            actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        return (driver, registry, controller)
    }

    /// Compiles and starts a real one-step "tap Second" scenario, gets it all the way to a PENDING approval
    /// against `obsA` (snapshot "snap_A"), then approves it. Returns the driver/registry/controller with the
    /// approval sitting in `.approved` status, bound to "snap_A" — ready for each test to inject its own
    /// stale-observation shape before calling `dispatchCurrentStep`.
    @discardableResult
    static func approvedTapSecondStep(scenarioID: String) async throws -> (FaultInjectingXCTestDriver, ToolRegistry, ScenarioExecutionController, Observation) {
        let (driver, registry, controller) = rig(scenarioID: scenarioID)
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "tap second", action: .tap, target: IRTarget(role: "button", label: "Second"),
                           verification: IRVerification(description: "d", signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:second")]))
        let ir = TestIR(testKey: scenarioID, title: "t", steps: [step])
        let validation = TestIRValidator.validate(ir)
        #expect(validation.isAccepted, "\(validation.rejectionReasons)")
        guard let scenario = TestIRExecutor.compileLinearScenario(testKey: scenarioID, title: "t", steps: ir.steps, verdicts: validation.stepVerdicts) else {
            Issue.record("failed to compile"); fatalError()
        }
        #expect(controller.startScenario(scenario))
        let obsA = tabsObservation(selected: "first", snapshotID: "snap_A")
        let executor = TestIRExecutor(controller: controller)
        guard case .pending = executor.proposeCurrentStep(freshObservation: obsA) else { Issue.record("expected pending"); fatalError() }
        controller.approveCurrentStep(source: .testAuthority)
        #expect(controller.activeApproval?.status == .approved)
        #expect(controller.activeApproval?.snapshotID == "snap_A")
        return (driver, registry, controller, obsA)
    }

    // MARK: - Real stale-snapshot TOCTOU: approved on A, simulator moved to B before dispatch.

    @Test("Approved on snapshot A; simulator state changes to snapshot B before dispatch -> dispatch rejected, no driver call, no retry")
    func testStaleSnapshotRejectedBeforeDispatch() async throws {
        let (driver, registry, controller, _) = try await Self.approvedTapSecondStep(scenarioID: "STALE-1")
        // Real state drift: a fresh observation arrives with a DIFFERENT snapshot ID before dispatch. The
        // approval is already `.approved` (not `.pending`), so `recordObservation`'s own auto-invalidation
        // (which only clears a PENDING approval) does not fire here — this is exactly the TOCTOU gap
        // `DispatchAuthorizer` exists to close at dispatch time.
        let obsB = Self.tabsObservation(selected: "second", snapshotID: "snap_B")
        controller.recordObservation(obsB)
        #expect(controller.activeApproval?.status == .approved, "approval status must not be silently rewritten before dispatch is attempted")

        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(let error) = result else { Issue.record("expected rejection, got \(result)"); return }
        guard case .staleSnapshot(let requested, let current) = error else { Issue.record("expected staleSnapshot, got \(error)"); return }
        #expect(requested == "snap_A")
        #expect(current == "snap_B")

        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0, "no ToolRegistry/driver mutation may occur on a stale-snapshot rejection")
        #expect(controller.activeApproval?.status == .failed, "the stale approval is marked failed, never silently retried")

        // No automatic retry: dispatching again without a fresh, matching observation must fail the same way.
        let retry = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = retry else { Issue.record("a stale/failed approval must never succeed on retry"); return }
        let mutationCountAfterRetry = await driver.mutationCallCount
        #expect(mutationCountAfterRetry == 0, "no retry of the mutation is permitted after an indeterminate/stale rejection")
    }

    @Test("Snapshot ID mismatch alone (identical elements, different snapshotID) still rejects dispatch")
    func testSnapshotIDMismatchAlone() async throws {
        let (driver, registry, controller, obsA) = try await Self.approvedTapSecondStep(scenarioID: "STALE-2")
        // Same elements as obsA, but a freshly-minted snapshot ID — mirrors the real, established fact that
        // every independent capture mints a new UUID-based snapshotID even when content is identical.
        let obsSameContentNewID = Observation(snapshotID: "snap_A_prime", bundleID: obsA.bundleID, appState: obsA.appState, elements: obsA.elements)
        controller.recordObservation(obsSameContentNewID)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(.staleSnapshot) = result else { Issue.record("expected staleSnapshot even with identical element content, got \(result)"); return }
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
    }

    @Test("Target element no longer exists in the current (same-snapshot-ID-window) observation -> elementNotFound, no dispatch")
    func testTargetNoLongerExists() async throws {
        let (driver, registry, controller, obsA) = try await Self.approvedTapSecondStep(scenarioID: "STALE-3")
        // Same snapshot ID as the approval (so this exercises the TARGET check, not the snapshot check), but
        // the approved element ID has been removed from the element list — simulates a real element
        // disappearing between approval and dispatch even within the "same" observed moment.
        let elementsWithoutTarget = obsA.elements.filter { $0.id != "e3" } // "Second" button removed
        let sameSnapshotMutatedElements = Observation(snapshotID: obsA.snapshotID, bundleID: obsA.bundleID, appState: obsA.appState, elements: elementsWithoutTarget)
        controller.recordObservation(sameSnapshotMutatedElements)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(.elementNotFound(let id)) = result else { Issue.record("expected elementNotFound, got \(result)"); return }
        #expect(id == "e3")
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
    }

    @Test("Same target identifier, but the element now belongs to a changed screen (role changed) -> typeMismatch, no dispatch")
    func testSameIdentifierChangedScreen() async throws {
        let (driver, registry, controller, obsA) = try await Self.approvedTapSecondStep(scenarioID: "STALE-4")
        // Same element ID ("e3"), same snapshot ID, but its role changed — simulates the accessibility tree
        // being reused/misattributed across an actual screen transition (the same identifier now names a
        // structurally different control).
        let mutated = obsA.elements.map { el -> UIElementSnapshot in
            guard el.id == "e3" else { return el }
            return UIElementSnapshot(id: el.id, role: "textField", label: el.label, identifier: el.identifier)
        }
        let sameSnapshotChangedRole = Observation(snapshotID: obsA.snapshotID, bundleID: obsA.bundleID, appState: obsA.appState, elements: mutated)
        controller.recordObservation(sameSnapshotChangedRole)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure(.typeMismatch(let expected, let actual, _)) = result else { Issue.record("expected typeMismatch, got \(result)"); return }
        #expect(expected == "button")
        #expect(actual == "textField")
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
    }

    // MARK: - Branch condition evaluated on old snapshot must not be reused/cached.

    @Test("A branch condition previously evaluated on an OLD observation is re-evaluated fresh, never reused from cache, when evaluated again with new data")
    func testBranchConditionNeverReusesOldSnapshot() async throws {
        let (_, _, controller) = Self.rig(scenarioID: "STALE-5")
        let branch = IRBranch(
            condition: .elementExists(IRTarget(role: "other", label: "tab:second")),
            thenSteps: [], elseSteps: [])
        let executor = TestIRExecutor(controller: controller)

        let obsFirst = Self.tabsObservation(selected: "first", snapshotID: "snap_old")
        let outcomeOld = executor.evaluateBranch(branch, freshObservation: obsFirst)
        guard case .selected(let armOld, let snapOld) = outcomeOld else { Issue.record("expected selected, got \(outcomeOld)"); return }
        #expect(armOld == .else, "tab:first observed -> condition not satisfied -> else")
        #expect(snapOld == "snap_old")

        // Evaluating the SAME IRBranch value again, now against a genuinely NEW observation, must reflect
        // the NEW state — never a cached decision from the old snapshot.
        let obsNew = Self.tabsObservation(selected: "second", snapshotID: "snap_new")
        let outcomeNew = executor.evaluateBranch(branch, freshObservation: obsNew)
        guard case .selected(let armNew, let snapNew) = outcomeNew else { Issue.record("expected selected, got \(outcomeNew)"); return }
        #expect(armNew == .then, "tab:second observed -> condition satisfied -> then; must differ from the earlier decision")
        #expect(snapNew == "snap_new")
        #expect(snapNew != snapOld)
    }
}
