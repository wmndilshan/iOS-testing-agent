import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Category L: EVIDENCE HONESTY. `RunTraceEvent` (unmodified) carries `runID` (stable for the
/// whole run) and `executionID` (a fresh, opaque UUID per dispatch) as two structurally DISTINCT fields —
/// every test here proves they are never confused, a failed dispatch's own trace event is never
/// indistinguishable from a successful one, and a verification failure is never silently relabeled.
@Suite("Fault-injection matrix.L Evidence Honesty Fault Injection")
@MainActor
struct EvidenceHonestyFaultTests {
    static func obs(snapshotID: String, tab: String = "first") -> Observation {
        Observation(snapshotID: snapshotID, bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "other", label: "tab:\(tab)", identifier: "fixture.tabs.status"),
            UIElementSnapshot(id: "e2", role: "button", label: "First"),
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ])
    }

    @Test("runID stays constant across every dispatch in one run; executionID is a fresh, distinct correlation ID per dispatch — the two are never the same value and never substitutable for each other")
    func testRunIDStableExecutionIDFreshPerDispatch() async throws {
        let step1 = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"),
                                  verification: ScenarioStepVerification(description: "d", requiredElements: [ScenarioExpectedElement(role: "other", identifier: "fixture.tabs.status", label: "tab:second", requireNonZeroBounds: false)]),
                                  signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:second")])
        let step2 = ScenarioStep(id: "s2", name: "tap first", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "First"),
                                  verification: ScenarioStepVerification(description: "d", requiredElements: [ScenarioExpectedElement(role: "other", identifier: "fixture.tabs.status", label: "tab:first", requireNonZeroBounds: false)]),
                                  signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:first")])
        let scenario = SafeScenario(id: "EVID-1", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, steps: [step1, step2])
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let mock = SimulatedDriver(currentSnapshot: Self.obs(snapshotID: "snap_1", tab: "first"))
        let driver = FaultInjectingXCTestDriver(inner: mock)
        // Real transitions queued for each dispatch's own post-action observation, so step 1 and step 2
        // both genuinely VERIFY and the controller's step index actually advances between them — otherwise
        // "step ordering violation" (correctly) blocks the second proposal, which is not what this test
        // is about.
        await driver.queueObservations([Self.obs(snapshotID: "snap_2", tab: "second"), Self.obs(snapshotID: "snap_3", tab: "first")])
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        let runIDAtStart = controller.activeRunTrace?.runID
        #expect(runIDAtStart != nil)

        // Dispatch 1
        controller.recordObservation(Self.obs(snapshotID: "snap_1", tab: "first"))
        let p1 = ActionProposal(scenarioID: "EVID-1", snapshotID: "snap_1", elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                 toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(p1) else { Issue.record("expected accepted"); return }
        controller.approveCurrentStep(source: .testAuthority)
        let r1 = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .success(let v1) = r1, v1.verified else { Issue.record("expected step 1 to verify, got \(r1)"); return }
        #expect(controller.currentStepIndex == 1, "step 1 verified — the controller must have advanced to step 2")

        // Dispatch 2
        let obsAfterStep1 = Self.obs(snapshotID: "snap_2", tab: "second")
        controller.recordObservation(obsAfterStep1)
        let p2 = ActionProposal(scenarioID: "EVID-1", snapshotID: obsAfterStep1.snapshotID, elementID: "e2", expectedRole: "button", expectedIdentifier: "First",
                                 toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 1, stepID: "s2")
        guard case .success = controller.handleProposal(p2) else { Issue.record("expected accepted for step 2"); return }
        controller.approveCurrentStep(source: .testAuthority)
        _ = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)

        let events = controller.activeRunTrace?.events ?? []
        let executionIDs = Set(events.compactMap(\.executionID))
        #expect(executionIDs.count == 2, "two distinct dispatches must carry two distinct executionIDs, got \(executionIDs)")
        #expect(events.allSatisfy { $0.runID == runIDAtStart }, "every event in this run carries the SAME runID — runID never drifts mid-run")
        for id in executionIDs {
            #expect(id != runIDAtStart, "executionID must never equal runID — they are structurally distinct correlation identities, never substitutable")
        }
    }

    @Test("A failed dispatch's own trace event carries a real failureClass and a result string that says 'failed', never a success-shaped message — failure can never be mistaken for positive evidence")
    func testFailedDispatchTraceNeverLooksLikeSuccess() async throws {
        let step = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"))
        let scenario = SafeScenario(id: "EVID-2", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: step)
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let mock = SimulatedDriver(currentSnapshot: Self.obs(snapshotID: "snap_1"))
        let driver = FaultInjectingXCTestDriver(inner: mock)
        await driver.failNextMutation(.actionFailed("real xcodebuild/tool failure"))
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        controller.recordObservation(Self.obs(snapshotID: "snap_1"))
        let proposal = ActionProposal(scenarioID: "EVID-2", snapshotID: "snap_1", elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                       toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected accepted"); return }
        controller.approveCurrentStep(source: .testAuthority)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .failure = result else { Issue.record("expected failure"); return }

        let events = controller.activeRunTrace?.events ?? []
        let finishedEvent = events.last { $0.eventType == .executionFinished }
        #expect(finishedEvent != nil)
        #expect(finishedEvent?.result.lowercased().contains("failed") == true, "the trace's own result string must honestly say 'failed', got: \(finishedEvent?.result ?? "nil")")
        #expect(!(finishedEvent?.result.lowercased().contains("succeeded") ?? false), "a failed dispatch's own event must never ALSO read as succeeded")
        #expect(controller.activeApproval?.executionSummary == nil, "no success summary may be recorded for a failed execution")
        #expect(controller.activeApproval?.executionError != nil, "the real error must be the recorded evidence, never silently dropped")
    }

    @Test("A verification failure (driver succeeded, postcondition did not hold) is recorded distinctly from a driver failure — evidence honestly distinguishes 'action failed' from 'action ran but did not achieve the requested state'")
    func testVerificationFailureDistinctFromDriverFailure() async throws {
        let step = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"),
                                 signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:second")])
        let obsBefore = Observation(snapshotID: "snap_pre", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "other", label: "tab:first", identifier: "fixture.tabs.status"),
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ])
        let obsAfterUnchanged = Observation(snapshotID: "snap_post", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "other", label: "tab:first", identifier: "fixture.tabs.status"), // never transitioned
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ])
        let scenario = SafeScenario(id: "EVID-3", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: step)
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let mock = SimulatedDriver(currentSnapshot: obsBefore)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        await driver.queueObservations([obsAfterUnchanged])
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        controller.recordObservation(obsBefore)
        let proposal = ActionProposal(scenarioID: "EVID-3", snapshotID: "snap_pre", elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                       toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected accepted"); return }
        controller.approveCurrentStep(source: .testAuthority)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .success(let verification) = result else { Issue.record("the driver DID succeed — this must be .success(verified:false), not a DriverError; got \(result)"); return }
        #expect(!verification.verified)
        // Distinct from the driver-failure test above: here `executionSummary`/`driverInvoked` DO reflect a
        // real, completed driver call, and `activeApproval.status` is `.succeeded` (the ACTION completed) —
        // it is `verification.verified` alone that is honestly false. Conflating these two would let a
        // verification failure disappear into a generic "failed" bucket indistinguishable from a real
        // driver-level failure.
        #expect(controller.activeApproval?.status == .succeeded, "the driver call itself completed — evidence must not relabel this as a driver failure")
        #expect(controller.activeApproval?.driverInvoked == true)
    }

}
