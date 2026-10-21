import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Category G: POST-ACTION VERIFICATION FAILURE. A trusted mutation executes, the driver reports
/// completion, but the FRESH post-action observation does not satisfy the step's own declared
/// postcondition. Every test proves the system never confuses "the driver returned successfully" with
/// "the requested state was verified" — the result is an explicit, honest verification failure, never a
/// success and never a fabricated LIVE_VERIFIED-equivalent, and no downstream mutating step is ever
/// dispatched off the back of it.
@Suite("Fault-injection matrix.G Post-Action Verification Fault Injection")
@MainActor
struct VerificationFaultTests {
    static func tabsObservation(selected: String, snapshotID: String) -> Observation {
        Observation(snapshotID: snapshotID, bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "other", label: "tab:\(selected)", identifier: "fixture.tabs.status"),
            UIElementSnapshot(id: "e2", role: "button", label: "First"),
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ])
    }

    @Test("Driver reports the tap succeeded, but the fresh post-observation shows NO state transition — result is verified:false, never a silent success, never conflated with 'driver returned successfully'")
    func testDriverSuccessWithoutStateTransitionIsVerificationFailure() async throws {
        let obsBefore = Self.tabsObservation(selected: "first", snapshotID: "snap_pre")
        // The postcondition the step declares ("labelBecame tab:second") never actually happens — the
        // driver's own tap call succeeds (real `SimulatedDriver.tap` returns a normal `ToolResult`), but the
        // world the fresh observation reports right after is UNCHANGED.
        let obsAfterUnchanged = Self.tabsObservation(selected: "first", snapshotID: "snap_post_unchanged")

        let mock = SimulatedDriver(currentSnapshot: obsBefore)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        await driver.queueObservations([obsAfterUnchanged])
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let step = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"),
                                 signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:second")])
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "VER-1", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: step)])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(id: "VER-1"))
        controller.recordObservation(obsBefore)
        let proposal = ActionProposal(scenarioID: "VER-1", snapshotID: obsBefore.snapshotID, elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                       toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected proposal accepted"); return }
        controller.approveCurrentStep(source: .testAuthority)

        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .success(let verification) = result else { Issue.record("the driver DID succeed at the mutation itself — the dispatch result is .success carrying a verification, not a DriverError; got \(result)"); return }
        #expect(!verification.verified, "the postcondition never held — this must be an explicit, honest verification failure")
        #expect(!verification.reason.isEmpty)

        // The mutation genuinely happened exactly once — this test is precisely about NOT treating that as
        // proof the requested state was reached.
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 1)
    }

    @Test("An unverified step's outcome is never reported as LIVE_VERIFIED-equivalent; verified:false is structurally distinct from verified:true")
    func testUnverifiedNeverIndistinguishableFromVerified() async throws {
        let obs = Self.tabsObservation(selected: "first", snapshotID: "snap_1")
        let mock = SimulatedDriver(currentSnapshot: obs)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        await driver.queueObservations([obs]) // no transition at all
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let step = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"),
                                 signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:second")])
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "VER-2", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: step)])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(id: "VER-2"))
        controller.recordObservation(obs)
        let proposal = ActionProposal(scenarioID: "VER-2", snapshotID: obs.snapshotID, elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                       toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected proposal accepted"); return }
        controller.approveCurrentStep(source: .testAuthority)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .success(let v1) = result else { Issue.record("expected .success(verified:false), got \(result)"); return }
        #expect(v1.verified == false)
        // The verification bit is a real, load-bearing Bool — Equatable/typed, never a string that could be
        // confused ("VERIFIED" vs "verified") — asserted here as a structural, not cosmetic, guarantee.
        #expect(type(of: v1.verified) == Bool.self)
    }

    @Test("Downstream mutating steps in the same scenario are never automatically dispatched after an unverified step — the controller's own step index does not advance past it")
    func testDownstreamStepNeverAutoDispatchedAfterUnverifiedStep() async throws {
        let obsBefore = Self.tabsObservation(selected: "first", snapshotID: "snap_pre")
        let obsAfterUnchanged = Self.tabsObservation(selected: "first", snapshotID: "snap_post_unchanged")
        let mock = SimulatedDriver(currentSnapshot: obsBefore)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        await driver.queueObservations([obsAfterUnchanged])
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let step1 = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"),
                                  signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:second")])
        let step2 = ScenarioStep(id: "s2", name: "tap first", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "First"),
                                  signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:first")])
        let scenario = SafeScenario(id: "VER-3", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, steps: [step1, step2])
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        controller.recordObservation(obsBefore)
        let proposal = ActionProposal(scenarioID: "VER-3", snapshotID: obsBefore.snapshotID, elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                       toolName: "tap_element", arguments: [:], reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected proposal accepted"); return }
        controller.approveCurrentStep(source: .testAuthority)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: "com.autonomous.agent.fixture", isLive: false)
        guard case .success(let verification) = result, !verification.verified else { Issue.record("expected an unverified step-1 result"); return }

        // The controller's step index must NOT have advanced to step 2 off the back of an unverified step 1.
        #expect(controller.currentStepIndex == 0, "an unverified mutating step must not silently advance the scenario to its downstream step")
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 1, "only step 1's own single real mutation occurred — step 2 was never dispatched")
    }
}
