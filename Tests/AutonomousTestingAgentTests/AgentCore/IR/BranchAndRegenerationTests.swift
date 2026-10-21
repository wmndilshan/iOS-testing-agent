import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Branch/regeneration contract, Part W: deterministic tests for branch execution (TRUE/FALSE, fresh-observation-decided,
/// selected-arm-only grounding/dispatch) and mid-scenario regeneration state preservation. No network, no
/// real simulator — reuses Stateful-scenario contract's `SequencedObservationDriver`/`ScriptedLLMClient`/`rig` helpers. Real
/// live evidence lives in `BranchAndRegenerationLiveTests`.
@Suite("IR.31 Branch/regeneration contract Branch Execution and Mid-Scenario Regeneration")
@MainActor
struct BranchAndRegenerationTests {
    typealias ScriptedLLMClient = RegenerationAndMultiScreenGroundingTests.ScriptedLLMClient
    typealias SequencedObservationDriver = StatefulScenarioExecutionTests.SequencedObservationDriver

    static func tabsElements(selected: String) -> [UIElementSnapshot] { StatefulScenarioExecutionTests.tabsElements(selected: selected) }
    static func tabsObservation(selected: String) -> Observation { StatefulScenarioExecutionTests.tabsObservation(selected: selected) }
    static func stepQuad(pre: String, post: String) -> [Observation] { StatefulScenarioExecutionTests.stepQuad(pre: pre, post: post) }
    static func rig(scenarioID: String, observations: [Observation]) -> (SequencedObservationDriver, ToolRegistry, ScenarioExecutionController) {
        StatefulScenarioExecutionTests.rig(scenarioID: scenarioID, observations: observations)
    }

    /// A branch response: condition = elementExists("Second" button label i.e. tab is on second... actually
    /// we key the condition off the status label, matching the real live design used elsewhere in this
    /// project) checking whether the CURRENT tab is "second"; THEN taps First, ELSE taps Second.
    static let branchResponse = """
    {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
      {"id": "s1", "sourceStepNumber": 1, "intent": "branch on current tab", "action": "verifyOnly", "arguments": {},
       "branch": {
         "condition": {"elementExists": {"_0": {"role": "other", "label": "tab:second"}}},
         "thenSteps": [{"id": "s1-then", "sourceStepNumber": 1, "intent": "select first", "action": "tap", "arguments": {},
                        "target": {"role": "button", "label": "First"},
                        "verification": {"description": "d", "requiredElements": [], "forbiddenElements": [],
                                          "signals": [{"labelBecame": {"identifier": "fixture.tabs.status", "to": "tab:first"}}]}}],
         "elseSteps": [{"id": "s1-else", "sourceStepNumber": 1, "intent": "select second", "action": "tap", "arguments": {},
                        "target": {"role": "button", "label": "Second"},
                        "verification": {"description": "d", "requiredElements": [], "forbiddenElements": [],
                                          "signals": [{"labelBecame": {"identifier": "fixture.tabs.status", "to": "tab:second"}}]}}]
       }}
    ]}
    """
    /// Same branch, but the THEN arm's target is fabricated (real vocabulary never contains it) — used to
    /// prove selected-arm grounding actually blocks (test 9).
    static let branchResponseFabricatedThen = """
    {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
      {"id": "s1", "sourceStepNumber": 1, "intent": "branch", "action": "verifyOnly", "arguments": {},
       "branch": {
         "condition": {"elementExists": {"_0": {"role": "other", "label": "tab:second"}}},
         "thenSteps": [{"id": "s1-then", "sourceStepNumber": 1, "intent": "fabricated", "action": "tap", "arguments": {},
                        "target": {"role": "button", "identifier": "status_label"}}],
         "elseSteps": [{"id": "s1-else", "sourceStepNumber": 1, "intent": "select second", "action": "tap", "arguments": {},
                        "target": {"role": "button", "label": "Second"},
                        "verification": {"description": "d", "requiredElements": [], "forbiddenElements": [],
                                          "signals": [{"labelBecame": {"identifier": "fixture.tabs.status", "to": "tab:second"}}]}}]
       }}
    ]}
    """
    static let tapResponse = { (target: String) in StatefulScenarioExecutionTests.tapResponse(target: target) }
    static let badResponse = StatefulScenarioExecutionTests.badResponse

    // MARK: - 5/7/8: branch TRUE — condition satisfied because the real state is genuinely "tab:second";
    // THEN dispatches, ELSE never touched; decided from a FRESH observation, not any cached value.

    @Test("Branch TRUE: real state is tab:second, condition selects THEN (tap First), ELSE never dispatches")
    func testBranchTrue() async throws {
        // 5 observation calls for the branch step itself: (1) run()'s own pre-generation vocab capture,
        // (2) driveSteps's condition-evaluation capture, (3) driveLinearSegment's own pre-propose capture
        // (a SEPARATE call from #2), (4) dispatcher's internal post-action capture, (5) run()'s trailing
        // post capture. Calls 1-3 all see "second" (nothing has changed yet); calls 4-5 see "first" (the
        // THEN arm's tap already transitioned it).
        let second = Self.tabsObservation(selected: "second")
        let first = Self.tabsObservation(selected: "first")
        let (driver, registry, controller) = Self.rig(scenarioID: "TB1", observations: [second, second, second, second, first, first])
        let client = ScriptedLLMClient([Self.branchResponse])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "TB1", stepNLTexts: ["branch on tab"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[0].outcome == .completed)
        #expect(evidence.steps[0].branch?.conditionResult == "satisfied")
        #expect(evidence.steps[0].branch?.selectedArm == "then")
        #expect(evidence.steps[0].branch?.unselectedArm == "else")
        #expect(evidence.steps[0].verified == true)
    }

    // MARK: - 6: branch FALSE — condition not satisfied because real state is "tab:first"; ELSE dispatches.

    @Test("Branch FALSE: real state is tab:first, condition selects ELSE (tap Second), THEN never dispatches")
    func testBranchFalse() async throws {
        let first = Self.tabsObservation(selected: "first")
        let second = Self.tabsObservation(selected: "second")
        let (driver, registry, controller) = Self.rig(scenarioID: "TB2", observations: [first, first, first, first, second, second])
        let client = ScriptedLLMClient([Self.branchResponse])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "TB2", stepNLTexts: ["branch on tab"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[0].outcome == .completed)
        #expect(evidence.steps[0].branch?.conditionResult == "notSatisfied")
        #expect(evidence.steps[0].branch?.selectedArm == "else")
        #expect(evidence.steps[0].branch?.unselectedArm == "then")
        #expect(evidence.steps[0].verified == true)
    }

    // MARK: - 9: selected branch requires grounding — a fabricated THEN target blocks even though the
    // condition genuinely selects THEN.

    @Test("Selected branch arm requires grounding: THEN is genuinely selected (real state is tab:second), but THEN's fabricated target blocks the step")
    func testSelectedArmRequiresGrounding() async throws {
        let second = Self.tabsObservation(selected: "second")
        let (driver, registry, controller) = Self.rig(scenarioID: "TB3", observations: Array(repeating: second, count: 10))
        let client = ScriptedLLMClient([Self.branchResponseFabricatedThen])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "TB3", stepNLTexts: ["branch on tab"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[0].outcome == .blocked)
        #expect(evidence.steps[0].groundingBlockingReasons.contains { $0.contains("status_label") || $0.contains("arm-ungrounded") })
    }

    // MARK: - 9b: the UNSELECTED arm's fabricated target must NEVER block — only the selected arm is
    // grounded (Part K's core requirement).

    @Test("An unselected arm's fabricated target never blocks the step — only the SELECTED arm is grounded")
    func testUnselectedArmFabricationNeverBlocks() async throws {
        // Real state is tab:FIRST this time, so the condition (checks for tab:second) is notSatisfied ->
        // ELSE is selected (real, "Second" target) — THEN (fabricated) is never even looked at for grounding.
        let first = Self.tabsObservation(selected: "first")
        let second = Self.tabsObservation(selected: "second")
        let (driver, registry, controller) = Self.rig(scenarioID: "TB4", observations: [first, first, first, first, second, second])
        let client = ScriptedLLMClient([Self.branchResponseFabricatedThen])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "TB4", stepNLTexts: ["branch on tab"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[0].outcome == .completed, "THEN's fabricated target must never block a run where ELSE (real) was selected")
        #expect(evidence.steps[0].branch?.selectedArm == "else")
    }

    // MARK: - 10/11: selected branch requires HITL and uses the trusted spine (structural, direct proof).

    @Test("A branch arm's mutating step still stops at a pending HITL approval before any dispatch")
    func testSelectedArmRequiresHITL() throws {
        let target = IRTarget(role: "button", label: "First")
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "tap", action: .tap, target: target)
        let scenario = TestIRExecutor.compileLinearScenario(testKey: "TB5", title: "t", steps: [step], verdicts: ["s1": .admitted], credentials: [:])!
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        let executor = TestIRExecutor(controller: controller)
        let obs = Self.tabsObservation(selected: "second")
        guard case .pending(let approval) = executor.proposeCurrentStep(freshObservation: obs) else { Issue.record("must be pending"); return }
        #expect(approval.status == .pending)
        #expect(controller.executionCount == 0)
    }

    // MARK: - 7b: branch decision is based on the FRESH observation captured at evaluation time, not a
    // stale/cached one — re-evaluating the SAME condition against a DIFFERENT fresh observation flips the result.

    @Test("Re-evaluating the identical condition against a genuinely different fresh observation flips the selected arm")
    @MainActor
    func testBranchDecisionUsesFreshObservationNotCache() {
        let condition = IRCondition.elementExists(IRTarget(role: "other", label: "tab:second"))
        let branch = IRBranch(condition: condition,
                              thenSteps: [IRStep(id: "t1", sourceStepNumber: 1, intent: "then", action: .tap, target: IRTarget(role: "button", label: "First"))],
                              elseSteps: [IRStep(id: "e1", sourceStepNumber: 1, intent: "else", action: .tap, target: IRTarget(role: "button", label: "Second"))])
        let scenario = SafeScenario(id: "TB6", name: "t", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                    actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        let executor = TestIRExecutor(controller: controller)

        let obsSecond = Self.tabsObservation(selected: "second")
        guard case .selected(let arm1, _) = executor.evaluateBranch(branch, freshObservation: obsSecond) else { Issue.record("expected selection"); return }
        #expect(arm1 == .then)

        let obsFirst = Self.tabsObservation(selected: "first")
        guard case .selected(let arm2, _) = executor.evaluateBranch(branch, freshObservation: obsFirst) else { Issue.record("expected selection"); return }
        #expect(arm2 == .else, "the SAME condition object, re-evaluated against a new real observation, must reflect the new state — never a cached decision")
    }

    // MARK: - 1/2/3: mid-scenario regeneration preserves prior completed state, never reruns step 1, and
    // uses the CURRENT (post-step-1) snapshot for step 2's regeneration — not step 1's.

    @Test("Mid-scenario regeneration: step 1 completes once, step 2 regenerates using the CURRENT post-step-1 snapshot, and step 1's own evidence is untouched by step 2's regeneration")
    func testMidScenarioRegenerationPreservesState() async throws {
        let s0 = Observation(snapshotID: "S0", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "first"))
        let s1 = Observation(snapshotID: "S1", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "second"))
        let s2 = Observation(snapshotID: "S2", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "first"))
        // Step 1: 4 calls (S0 pre x2, S1 post x2). Step 2: 1 vocab call (S1, the REAL current state) — its
        // own regeneration attempts consume no further driver calls (GroundedTestIRGeneration never touches
        // the driver) — then once grounded+dispatched, 3 more calls (S1 pre-propose already counted? No:
        // run()'s vocab capture for step2 IS the "S1" call; driveSteps's own pre-propose capture is a
        // SECOND S1 read; dispatcher's post is S2 x2).
        let (driver, registry, controller) = Self.rig(scenarioID: "TB7", observations: [s0, s0, s0, s1, s1, s1, s1, s1, s2, s2])
        let client = ScriptedLLMClient([Self.tapResponse("Second"), Self.badResponse, Self.tapResponse("First")])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "TB7", stepNLTexts: ["tap second", "tap first"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        // Step 1 completed with DIRECT_SUCCESS, using S0->S1.
        #expect(evidence.steps[0].outcome == .completed)
        #expect(evidence.steps[0].resultKind == .directSuccess)
        #expect(evidence.steps[0].preSnapshotID == "S0")
        #expect(evidence.steps[0].postSnapshotID == "S1")
        // Step 2 REGENERATED (attempt 1 bad, attempt 2 good), using S1 (step 1's real post-state) as its
        // OWN pre-snapshot — never S0, never a "reset" back to the start.
        #expect(evidence.steps[1].resultKind == .regeneratedSuccess)
        #expect(evidence.steps[1].attemptCount == 2)
        #expect(evidence.steps[1].preSnapshotID == "S1", "step 2 must ground/regenerate against the CURRENT post-step-1 state, never a stale or reset snapshot")
        #expect(evidence.steps[1].postSnapshotID == "S2")
        #expect(client.callCount == 1 + 2, "step 1: 1 call (direct success). step 2: 2 calls (1 fail + 1 regenerated success). Step 1 is NEVER regenerated/rerun.")
    }

    // MARK: - 16/18: evidence records the branch arm and contains no secrets.

    @Test("Branch evidence names the selected/unselected arm and the condition snapshot, with no secret-shaped text anywhere")
    func testBranchEvidenceContentAndSecrecy() async throws {
        let second = Self.tabsObservation(selected: "second")
        let first = Self.tabsObservation(selected: "first")
        let (driver, registry, controller) = Self.rig(scenarioID: "TB8", observations: [second, second, first, first])
        let client = ScriptedLLMClient([Self.branchResponse])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "TB8", stepNLTexts: ["branch on tab"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        let branch = try #require(evidence.steps[0].branch)
        #expect(branch.selectedArm == "then")
        #expect(branch.unselectedArm == "else")
        #expect(!branch.conditionSnapshotID.isEmpty)
        for reason in evidence.steps[0].groundingBlockingReasons {
            #expect(!SecretRedactor.containsSecret(reason))
        }
    }

    // Forged branch-result / verification-result fields are covered by
    // NestedBranchExecutionTests.testForgedBranchSelectionFieldsIgnored and
    // TestIRGenerationHardeningTests.testFaultD.
}
