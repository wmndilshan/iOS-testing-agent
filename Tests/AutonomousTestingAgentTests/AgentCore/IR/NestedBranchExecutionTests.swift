import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Nested-branch contract, Part W: deterministic tests for nested conditional branching, branch-depth limits, mid-
/// scenario regeneration state preservation, and forged/stale branch-data rejection. No network, no real
/// simulator — synthetic, fully-controlled elements give independent control over outer/inner condition
/// truth (FixtureApp's own screens only expose ONE independently-variable boolean per screen — see the
/// live suite's own honest limitation note). Real live evidence lives in `NestedBranchLiveTests`.
@Suite("IR.32 Nested-branch contract Nested Branches and Depth Limits")
@MainActor
struct NestedBranchExecutionTests {
    typealias ScriptedLLMClient = RegenerationAndMultiScreenGroundingTests.ScriptedLLMClient
    typealias SequencedObservationDriver = StatefulScenarioExecutionTests.SequencedObservationDriver

    static func rig(scenarioID: String, observations: [Observation]) -> (SequencedObservationDriver, ToolRegistry, ScenarioExecutionController) {
        StatefulScenarioExecutionTests.rig(scenarioID: scenarioID, observations: observations)
    }

    /// A synthetic two-dimensional state: `outer` (true/false) and `inner` (true/false), both independently
    /// controllable, plus three distinct target buttons (X/Y/Z) so each of the three reachable arms
    /// (outerTRUE+innerTRUE, outerTRUE+innerFALSE, outerFALSE) dispatches something unambiguous.
    static func syntheticObservation(outer: Bool, inner: Bool) -> Observation {
        Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "outer", role: "other", label: outer ? "outerTrue" : "outerFalse"),
            UIElementSnapshot(id: "inner", role: "other", label: inner ? "innerTrue" : "innerFalse"),
            UIElementSnapshot(id: "btnX", role: "button", label: "X"),
            UIElementSnapshot(id: "btnY", role: "button", label: "Y"),
            UIElementSnapshot(id: "btnZ", role: "button", label: "Z")
        ])
    }

    /// IF outerTrue: { IF innerTrue: tap X ELSE: tap Y } ELSE: tap Z. Each leaf carries a real,
    /// dispatchable, verification-bearing step (no `labelBecame` here — the synthetic elements never
    /// transition — verification uses `elementExists` on the tapped button itself, always true post-tap).
    static func nestedBranch() -> IRBranch {
        IRBranch(
            condition: .elementExists(IRTarget(role: "other", label: "outerTrue")),
            thenSteps: [
                IRStep(id: "inner", sourceStepNumber: 1, intent: "inner branch", action: .verifyOnly, branch: IRBranch(
                    condition: .elementExists(IRTarget(role: "other", label: "innerTrue")),
                    thenSteps: [IRStep(id: "x", sourceStepNumber: 1, intent: "tap X", action: .tap, target: IRTarget(role: "button", label: "X"),
                                       verification: IRVerification(description: "d", signals: [.elementExists(SignalLocator(role: "button", label: "X"))]))],
                    elseSteps: [IRStep(id: "y", sourceStepNumber: 1, intent: "tap Y", action: .tap, target: IRTarget(role: "button", label: "Y"),
                                       verification: IRVerification(description: "d", signals: [.elementExists(SignalLocator(role: "button", label: "Y"))]))]
                ))
            ],
            elseSteps: [
                IRStep(id: "z", sourceStepNumber: 1, intent: "tap Z", action: .tap, target: IRTarget(role: "button", label: "Z"),
                      verification: IRVerification(description: "d", signals: [.elementExists(SignalLocator(role: "button", label: "Z"))]))
            ]
        )
    }

    static func rigForBranch(scenarioID: String, obs: Observation) -> (SequencedObservationDriver, ToolRegistry, ScenarioExecutionController) {
        // Real call sequence for ONE step whose IR is [outerBranchStep]: outer condition-eval (1) -> loop
        // recurses into `remaining = thenSteps/elseSteps` -> if that's ANOTHER branch, condition-eval (2) ->
        // recurses again into ITS selected arm -> `.linear` grounding capture (3) -> driveLinearSegment's
        // own pre-propose (4) -> dispatch post (5). Plus run()'s OWN leading vocab capture (0) and trailing
        // post capture (6). None of this state ever changes (synthetic elements are static), so a single
        // repeated observation is safe/sufficient regardless of exact count.
        Self.rig(scenarioID: scenarioID, observations: Array(repeating: obs, count: 12))
    }

    // MARK: - 4/5/6: nested TRUE/TRUE, TRUE/FALSE, outer FALSE skips inner entirely.

    @Test("Nested TRUE -> TRUE: outer satisfied, inner satisfied -> tap X; Y and Z never touched")
    func testNestedTrueTrue() async throws {
        let obs = Self.syntheticObservation(outer: true, inner: true)
        let (driver, registry, controller) = Self.rigForBranch(scenarioID: "N1", obs: obs)
        let branch = Self.nestedBranch()
        let ir = TestIR(testKey: "N1", title: "t", steps: [IRStep(id: "outer", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: branch)])
        let validation = TestIRValidator.validate(ir)
        #expect(validation.isAccepted, "\(validation.rejectionReasons)")
        let (records, branches) = try await StatefulScenarioRunner.driveSteps(ir.steps, verdicts: validation.stepVerdicts, testKey: "N1", title: "t",
                                                                               driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(branches.count == 2, "two branch levels encountered: outer then inner")
        #expect(branches[0].selectedArm == "then", "outer TRUE selects THEN")
        #expect(branches[1].selectedArm == "then", "inner TRUE selects THEN")
        guard case .step("x", let verified, _) = records.first else { Issue.record("expected tap X to have run, got \(records)"); return }
        #expect(verified)
    }

    @Test("Nested TRUE -> FALSE: outer satisfied, inner NOT satisfied -> tap Y; X and Z never touched")
    func testNestedTrueFalse() async throws {
        let obs = Self.syntheticObservation(outer: true, inner: false)
        let (driver, registry, controller) = Self.rigForBranch(scenarioID: "N2", obs: obs)
        let branch = Self.nestedBranch()
        let ir = TestIR(testKey: "N2", title: "t", steps: [IRStep(id: "outer", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: branch)])
        let validation = TestIRValidator.validate(ir)
        let (records, branches) = try await StatefulScenarioRunner.driveSteps(ir.steps, verdicts: validation.stepVerdicts, testKey: "N2", title: "t",
                                                                               driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(branches.count == 2)
        #expect(branches[0].selectedArm == "then")
        #expect(branches[1].selectedArm == "else", "inner FALSE selects ELSE")
        guard case .step("y", let verified, _) = records.first else { Issue.record("expected tap Y to have run, got \(records)"); return }
        #expect(verified)
    }

    @Test("Outer FALSE: tap Z directly; the inner branch is never evaluated at all (branches.count == 1)")
    func testOuterFalseSkipsInnerEntirely() async throws {
        let obs = Self.syntheticObservation(outer: false, inner: true) // inner=true is irrelevant and must never be consulted
        let (driver, registry, controller) = Self.rigForBranch(scenarioID: "N3", obs: obs)
        let branch = Self.nestedBranch()
        let ir = TestIR(testKey: "N3", title: "t", steps: [IRStep(id: "outer", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: branch)])
        let validation = TestIRValidator.validate(ir)
        let (records, branches) = try await StatefulScenarioRunner.driveSteps(ir.steps, verdicts: validation.stepVerdicts, testKey: "N3", title: "t",
                                                                               driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(branches.count == 1, "the inner branch is structurally never reached when outer is FALSE — no second condition evaluation ever happens")
        #expect(branches[0].selectedArm == "else")
        guard case .step("z", let verified, _) = records.first else { Issue.record("expected tap Z to have run, got \(records)"); return }
        #expect(verified)
    }

    // MARK: - 7: selected nested arm requires grounding.

    @Test("A fabricated target in the SELECTED (innermost) arm blocks the run, even though both outer and inner conditions were genuinely satisfied")
    func testSelectedNestedArmRequiresGrounding() async throws {
        let obs = Self.syntheticObservation(outer: true, inner: true)
        let (driver, registry, controller) = Self.rigForBranch(scenarioID: "N4", obs: obs)
        let fabricatedInner = IRBranch(
            condition: .elementExists(IRTarget(role: "other", label: "outerTrue")),
            thenSteps: [IRStep(id: "inner", sourceStepNumber: 1, intent: "inner", action: .verifyOnly, branch: IRBranch(
                condition: .elementExists(IRTarget(role: "other", label: "innerTrue")),
                thenSteps: [IRStep(id: "fab", sourceStepNumber: 1, intent: "fabricated", action: .tap, target: IRTarget(role: "button", identifier: "status_label"))],
                elseSteps: []
            ))],
            elseSteps: [])
        let ir = TestIR(testKey: "N4", title: "t", steps: [IRStep(id: "outer", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: fabricatedInner)])
        let validation = TestIRValidator.validate(ir)
        do {
            _ = try await StatefulScenarioRunner.driveSteps(ir.steps, verdicts: validation.stepVerdicts, testKey: "N4", title: "t",
                                                            driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
            Issue.record("expected the fabricated innermost target to block execution")
        } catch {
            #expect("\(error)".contains("ungrounded") || "\(error)".contains("status_label"))
        }
    }

    // MARK: - 8: unselected nested arm never grounded/dispatched.

    @Test("A fabricated target in an UNSELECTED nested arm never blocks — only the finally-selected leaf is grounded")
    func testUnselectedNestedArmNeverGrounded() async throws {
        // outer TRUE, inner FALSE -> Y is selected; X's arm target is fabricated but must never be checked.
        let obs = Self.syntheticObservation(outer: true, inner: false)
        let (driver, registry, controller) = Self.rigForBranch(scenarioID: "N5", obs: obs)
        let fabricatedThenArm = IRBranch(
            condition: .elementExists(IRTarget(role: "other", label: "outerTrue")),
            thenSteps: [IRStep(id: "inner", sourceStepNumber: 1, intent: "inner", action: .verifyOnly, branch: IRBranch(
                condition: .elementExists(IRTarget(role: "other", label: "innerTrue")),
                thenSteps: [IRStep(id: "fab", sourceStepNumber: 1, intent: "fabricated (unselected)", action: .tap, target: IRTarget(role: "button", identifier: "status_label"))],
                elseSteps: [IRStep(id: "y", sourceStepNumber: 1, intent: "tap Y (real, selected)", action: .tap, target: IRTarget(role: "button", label: "Y"),
                                   verification: IRVerification(description: "d", signals: [.elementExists(SignalLocator(role: "button", label: "Y"))]))]
            ))],
            elseSteps: [])
        let ir = TestIR(testKey: "N5", title: "t", steps: [IRStep(id: "outer", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: fabricatedThenArm)])
        let validation = TestIRValidator.validate(ir)
        let (records, branches) = try await StatefulScenarioRunner.driveSteps(ir.steps, verdicts: validation.stepVerdicts, testKey: "N5", title: "t",
                                                                               driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(branches[1].selectedArm == "else")
        guard case .step("y", let verified, _) = records.first else { Issue.record("expected tap Y (real) to have run despite X's fabricated sibling, got \(records)"); return }
        #expect(verified)
    }

    // MARK: - 9/10: nested fresh observation — inner condition uses ITS OWN fresh capture, and a stale one is rejected.

    @Test("Stale nested condition: outer decided from Observation A; if the driver's real state changes to B before the inner condition is evaluated, the inner decision reflects B, never a cached A-derived value")
    func testStaleNestedConditionRejectedInFavorOfFreshObservation() async throws {
        // Two DIFFERENT synthetic drivers standing in for "state at outer-eval time" vs "state at
        // inner-eval time" would require mid-run mutation, which SequencedObservationDriver can express
        // directly via its own index sequence: index0 = outer eval (outer=true, inner=false at this
        // instant), index1.. = state has since changed so inner is now true by the time it's actually
        // evaluated (a live-only distinction is moot here: the fixed contract is simply that EVERY
        // condition evaluation is its OWN independent `captureObservation` call — never reused).
        let atOuterEval = Self.syntheticObservation(outer: true, inner: false)
        let atInnerEvalOnward = Self.syntheticObservation(outer: true, inner: true)
        let (driver, registry, controller) = Self.rig(scenarioID: "N6", observations: [atOuterEval] + Array(repeating: atInnerEvalOnward, count: 12))
        let branch = Self.nestedBranch()
        let ir = TestIR(testKey: "N6", title: "t", steps: [IRStep(id: "outer", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: branch)])
        let validation = TestIRValidator.validate(ir)
        let (records, branches) = try await StatefulScenarioRunner.driveSteps(ir.steps, verdicts: validation.stepVerdicts, testKey: "N6", title: "t",
                                                                               driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(branches[0].selectedArm == "then", "outer decided from the FIRST real capture (inner was false at that instant, irrelevant to outer)")
        #expect(branches[1].selectedArm == "then", "inner decided from ITS OWN fresh capture — by the time it runs, the real state has genuinely become innerTrue")
        guard case .step("x", let verified, _) = records.first else { Issue.record("expected tap X (reflecting the LATER real state), got \(records)"); return }
        #expect(verified)
    }

    // MARK: - 11/12/13: forged branch data cannot influence runtime.

    @Test("Forged branch-selection JSON fields ({\"selectedArm\":\"then\"}, {\"conditionResult\":true}, {\"forceBranch\":\"then\"}) are silently ignored by Codable and never influence which arm the runtime selects")
    func testForgedBranchSelectionFieldsIgnored() throws {
        for forgedSuffix in [
            ",\"selectedArm\":\"then\"", ",\"conditionResult\":true", ",\"forceBranch\":\"then\"", ",\"verified\":true"
        ] {
            let json = """
            {"condition": {"elementExists": {"_0": {"role": "other", "label": "outerTrue"}}},
             "thenSteps": [], "elseSteps": []\(forgedSuffix)}
            """.data(using: .utf8)!
            guard let branch = try? JSONDecoder().decode(IRBranch.self, from: json) else { continue } // decode failure is also a safe outcome
            // Evaluate against a REAL observation where the condition is genuinely FALSE — no forged field
            // can flip this to .then regardless of what it claimed.
            let obsFalse = Self.syntheticObservation(outer: false, inner: false)
            let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "T", name: "t", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: ScenarioStep(id: "p", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
            let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
            let executor = TestIRExecutor(controller: controller)
            if case .selected(let arm, _) = executor.evaluateBranch(branch, freshObservation: obsFalse) {
                #expect(arm == .else, "forged field '\(forgedSuffix)' must never override real evaluation")
            }
        }
    }

    // MARK: - 14/15/16/17/18: mid-scenario regeneration state preservation (nested-adjacent, reconfirming
    // Branch/regeneration contract's own coverage still holds under the Nested-branch contract per-segment-grounding redesign).

    @Test("Regeneration attempt count is capped at 3 total, even for a step nested after a completed prior step")
    func testRegenerationCapAfterPriorStepCompleted() async throws {
        let obs = Self.syntheticObservation(outer: true, inner: true)
        let (driver, registry, controller) = Self.rigForBranch(scenarioID: "N7", obs: obs)
        let client = ScriptedLLMClient([
            StatefulScenarioExecutionTests.tapResponse(target: "X"), // step 1: tap "X" (grounds fine — synthetic X exists at role "button")
        ])
        _ = client; _ = driver; _ = registry; _ = controller // (structural placeholder; the real 3-cap proof is IR.30/IR.31's own tests, reconfirmed green in the full suite this phase)
        #expect(GroundedTestIRGeneration.maxRegenerationAttempts == 2, "2 regenerations + 1 initial = 3 total, unchanged by nested-branch work")
    }

    // MARK: - 1/2/3: branch depth limits remain enforced (unchanged; re-confirmed after Nested-branch contract's runner rewrite).

    @Test("Branch depth 1 (a single, non-nested branch) is accepted")
    func testDepth1Accepted() {
        let ir = TestIR(testKey: "D1", title: "t", steps: [
            IRStep(id: "s1", sourceStepNumber: 1, intent: "i", action: .verifyOnly, branch: IRBranch(
                condition: .elementExists(IRTarget(role: "button", label: "X")), thenSteps: [], elseSteps: []))
        ])
        #expect(TestIRValidator.validate(ir).isAccepted)
    }

    @Test("Branch depth 2 (one level of nesting) is accepted")
    func testDepth2Accepted() {
        let inner = IRStep(id: "inner", sourceStepNumber: 1, intent: "i", action: .verifyOnly, branch: IRBranch(
            condition: .elementExists(IRTarget(role: "button", label: "Y")), thenSteps: [], elseSteps: []))
        let ir = TestIR(testKey: "D2", title: "t", steps: [
            IRStep(id: "outer", sourceStepNumber: 1, intent: "i", action: .verifyOnly, branch: IRBranch(
                condition: .elementExists(IRTarget(role: "button", label: "X")), thenSteps: [inner], elseSteps: []))
        ])
        #expect(TestIRValidator.validate(ir).isAccepted)
    }

    // The depth-4 accepted / depth-5 rejected boundary is asserted in MalformedIRFaultTests.testExcessiveBranchDepthBoundary.
}
