import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Live-execution contract, section 16: fault injection for the real-simulator-execution safety gates. These run OFFLINE
/// (no simulator, no xcodebuild) against genuine data captured live during this phase's own real runs
/// (`SimulatorExecutionLiveTests`) — real element shapes, not synthesized fixtures — so the
/// safety-gate proofs are grounded in the same real accessibility tree the live tests actually saw, without
/// paying for another `xcodebuild test` invocation per fault.
///
/// Faults A/B/C (forcing the semantic gate to mismatch, the validator to reject, and the condition
/// evaluator to be indeterminate) are temporary source edits applied and reverted manually, exactly the
/// discipline established in Adversarial-IR contract: baseline `shasum`, inject, rebuild, confirm the probe test below
/// fails as expected, revert byte-for-byte, re-`shasum -c`. They are not automated in this file — a test
/// that edits and rebuilds the package from inside `swift test` is exactly the kind of fragile, hard-to-audit
/// machinery this project avoids. Faults D and E need no mutation at all and are ordinary, permanent tests.
@Suite("Live-execution contract Fault Injection (offline, real captured data)")
struct TrustedExecutionCapturedDataFaultTests {
    /// The real "tap" screen's captured elements (Live-execution contract's own live smoke-test run) — role/identifier/
    /// label transcribed verbatim from the exported `AccessibilityTreeSnapshot` JSON attachment.
    static func realTapScreenElements(statusLabel: String) -> [UIElementSnapshot] {
        [
            UIElementSnapshot(id: "elem_1", role: "window", depth: 1),
            UIElementSnapshot(id: "elem_6", role: "other", label: statusLabel, identifier: "fixture.tap.status", isEnabled: true, isHittable: true),
            UIElementSnapshot(id: "elem_7", role: "button", label: "Tap target", identifier: "fixture.tap.target", isEnabled: true, isHittable: true),
            UIElementSnapshot(id: "elem_8", role: "staticText", label: statusLabel, isEnabled: true, isHittable: true)
        ]
    }
    static func realObservation(statusLabel: String) -> Observation {
        Observation(snapshotID: "real_captured_tap", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: realTapScreenElements(statusLabel: statusLabel))
    }

    // MARK: - Fault A probe: with SemanticExpectation.swift's gate forced to always report mismatch
    // (temporary manual edit; see the Live-execution contract report), a genuinely-matching real expectation must report
    // mismatch, proving a harness that checks `classification == .exactMatch` before executing would refuse.

    @Test("Fault A probe: run once under the manually-injected forced-mismatch build; a genuinely-matching expectation must report mismatch")
    func testFaultA_Probe() {
        let ir = TestIR(testKey: "PROBE", title: "probe", steps: [
            IRStep(id: "s1", sourceStepNumber: 1, intent: "tap", action: .tap, target: IRTarget(role: "button", label: "Tap target"))
        ])
        let expectation = SemanticExpectation(caseID: "PROBE", expectedActions: ["tap"], requiredTargetLabels: ["Tap target"])
        let result = SemanticFidelityGate.evaluate(expectation: expectation, against: ir)
        #expect(result.classification == .exactMatch, "baseline (unfaulted) run: this must genuinely be exactMatch, confirming Fault A's later mismatch is the fault's doing, not a bad test")
    }

    // MARK: - Fault B probe: with TestIRValidator.validate forced to always reject (temporary manual edit),
    // a known-good, previously-accepted real document must be rejected.

    @Test("Fault B probe: run once under the manually-injected forced-rejection build; a genuinely-accepted real document must be rejected")
    func testFaultB_Probe() {
        let step = IRStep(id: "s1_existence", sourceStepNumber: 1, intent: "verify the tap target exists", action: .verifyOnly,
                          verification: IRVerification(description: "target exists", signals: [.elementExists(SignalLocator(role: "button", identifier: "fixture.tap.target"))]))
        let ir = TestIR(testKey: "LIVE-EXECUTION-SMOKE", title: "Live-execution contract deterministic smoke test", steps: [step])
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted, "baseline (unfaulted) run: this must genuinely be accepted, confirming Fault B's later rejection is the fault's doing, not a bad test")
    }

    // MARK: - Fault C probe: with IRConditionEvaluator.evaluate forced to always be indeterminate (temporary
    // manual edit), a condition that is genuinely, unambiguously satisfied against real captured tap-screen
    // data must be reported indeterminate, proving neither branch arm would ever be dispatched.

    @Test("Fault C probe: run once under the manually-injected forced-indeterminate build; a genuinely-satisfied real condition must be indeterminate")
    func testFaultC_Probe() {
        let obs = Self.realObservation(statusLabel: "tap:idle")
        let condition = IRCondition.elementExists(IRTarget(role: "button", identifier: "fixture.tap.target"))
        let outcome = IRConditionEvaluator.evaluate(condition, in: obs)
        guard case .satisfied = outcome else { Issue.record("baseline (unfaulted) run: this must genuinely be satisfied, confirming Fault C's later indeterminacy is the fault's doing, not a bad test"); return }
    }

    // MARK: - Fault D (no mutation needed): the semantic gate is never an execution/verification authority.
    // Real post-action data captured live (status genuinely read "tap:tapped") proves that even if the gate
    // were faked to claim exactMatch (Adversarial-IR contract's own Fault D already proved this structurally in isolation),
    // the real `ScenarioVerificationService` — protected, never touched — independently and correctly
    // reports failure against a wrong expectation.

    @Test("Fault D (no mutation needed): real captured post-action data proves ScenarioVerificationService's verdict is independent of and cannot be overridden by any semantic-gate claim")
    func testFaultD_VerificationIndependentOfGate() {
        let post = Self.realObservation(statusLabel: "tap:tapped") // genuine post-tap state, captured live
        let step = ScenarioStep(id: "s1", name: "tap", description: "tap", toolName: "tap_element",
                                locator: ScenarioLocator(role: "button", identifier: "fixture.tap.target"),
                                verification: ScenarioStepVerification(description: "wrong expectation",
                                                                       requiredElements: [ScenarioExpectedElement(role: "other", label: "tap:WRONG", requireNonZeroBounds: false)]))
        let scenario = SafeScenario(id: "s", name: "s", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: step)
        let result = ScenarioVerificationService().verify(step: step, scenario: scenario, observation: post, pre: post)
        #expect(!result.verified, "the real verification service must never be swayed by a claim it never even sees — it fails purely on its own required-element check")
    }

    // MARK: - Fault E (no mutation needed): an approval bypass attempt is caught by the existing,
    // unmodified trusted spine.

    @Test("Fault E (no mutation needed): dispatch without approval is refused by the existing, unmodified trusted spine — reusing the exact real proposal shape Live-execution contract's own live HITL proof produced")
    @MainActor
    func testFaultE_ApprovalBypassRefused() async {
        let placeholder = ScenarioStep(id: "placeholder", name: "placeholder", description: "placeholder", toolName: "tap_element", locator: ScenarioLocator(role: "button"))
        let scenario = SafeScenario(id: "T", name: "t", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: placeholder)
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        let obs = Self.realObservation(statusLabel: "tap:idle")
        controller.recordObservation(obs)
        // No handleProposal / approveCurrentStep call at all — dispatch is attempted directly.
        let driver = SimulatedDriver(currentSnapshot: obs)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry)
        guard case .failure = result else { Issue.record("dispatch without any approval must be refused"); return }
        #expect(await driver.invokedActionCount["tap"] == nil, "no real action must ever be invoked without an approval")
    }
}
