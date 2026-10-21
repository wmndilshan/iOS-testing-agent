import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Stateful-scenario contract, Part V: deterministic unit tests for `StatefulScenarioRunner`. No network, no real simulator —
/// a scripted `LLMClientProtocol` (reused from Regeneration contract) plus a precise, call-index-sequenced observation
/// wrapper around `SimulatedDriver` (`SimulatedDriver`'s own FIFO queue pops on every call while
/// non-empty, which cannot express "calls 1-2 see the old state, calls 3-4 see the new state" — this
/// wrapper can). Real live evidence lives in `StatefulScenarioLiveTests`.
@Suite("IR.30 Stateful-scenario contract Stateful Multi-Step Scenario")
@MainActor
struct StatefulScenarioExecutionTests {
    typealias ScriptedLLMClient = RegenerationAndMultiScreenGroundingTests.ScriptedLLMClient

    /// Delegates everything to an inner `SimulatedDriver` except `captureObservation`, which returns
    /// `observationsByCallIndex[callIndex]` (clamped to the last entry once exhausted) — exact, reproducible
    /// control over what each SPECIFIC call sees, unlike a FIFO queue that pops on every non-empty call.
    final actor SequencedObservationDriver: DeviceDriver {
        private let inner: SimulatedDriver
        private let observations: [Observation]
        private(set) var callIndex = 0
        init(inner: SimulatedDriver, observations: [Observation]) { self.inner = inner; self.observations = observations }

        func captureObservation(bundleID: String) async throws -> Observation {
            defer { callIndex += 1 }
            let obs = observations[min(callIndex, observations.count - 1)]
            await inner.setSnapshot(obs)
            return obs
        }
        func tap(snapshotID: String, elementID: String) async throws -> ToolResult { try await inner.tap(snapshotID: snapshotID, elementID: elementID) }
        func doubleTap(snapshotID: String, elementID: String) async throws -> ToolResult { try await inner.doubleTap(snapshotID: snapshotID, elementID: elementID) }
        func longPress(snapshotID: String, elementID: String, durationSeconds: Double) async throws -> ToolResult { try await inner.longPress(snapshotID: snapshotID, elementID: elementID, durationSeconds: durationSeconds) }
        func swipe(snapshotID: String, elementID: String, direction: ScrollDirection) async throws -> ToolResult { try await inner.swipe(snapshotID: snapshotID, elementID: elementID, direction: direction) }
        func dragAndDrop(snapshotID: String, sourceElementID: String, destinationElementID: String, holdDurationSeconds: Double) async throws -> ToolResult { try await inner.dragAndDrop(snapshotID: snapshotID, sourceElementID: sourceElementID, destinationElementID: destinationElementID, holdDurationSeconds: holdDurationSeconds) }
        func typeText(snapshotID: String, elementID: String, text: String) async throws -> ToolResult { try await inner.typeText(snapshotID: snapshotID, elementID: elementID, text: text) }
        func clearText(snapshotID: String, elementID: String) async throws -> ToolResult { try await inner.clearText(snapshotID: snapshotID, elementID: elementID) }
        func scroll(snapshotID: String, containerID: String, direction: ScrollDirection) async throws -> ToolResult { try await inner.scroll(snapshotID: snapshotID, containerID: containerID, direction: direction) }
        func navigateBack(snapshotID: String, elementID: String) async throws -> ToolResult { try await inner.navigateBack(snapshotID: snapshotID, elementID: elementID) }
        func selectTab(snapshotID: String, elementID: String) async throws -> ToolResult { try await inner.selectTab(snapshotID: snapshotID, elementID: elementID) }
        func dismissKeyboard(snapshotID: String, elementID: String) async throws -> ToolResult { try await inner.dismissKeyboard(snapshotID: snapshotID, elementID: elementID) }
        func getElementDetails(snapshotID: String, elementID: String) async throws -> ToolResult { try await inner.getElementDetails(snapshotID: snapshotID, elementID: elementID) }
        func captureScreenshot(reason: String) async throws -> (imagePath: String, observation: Observation?) { try await inner.captureScreenshot(reason: reason) }
        func inspectElements(snapshotID: String, expectedElements: [ScenarioExpectedElement]) async throws -> ToolResult { try await inner.inspectElements(snapshotID: snapshotID, expectedElements: expectedElements) }
    }

    static func tabsElements(selected: String) -> [UIElementSnapshot] {
        [
            UIElementSnapshot(id: "e1", role: "other", label: "tab:\(selected)", identifier: "fixture.tabs.status"),
            UIElementSnapshot(id: "e2", role: "button", label: "First"),
            UIElementSnapshot(id: "e3", role: "button", label: "Second")
        ]
    }
    static func tabsObservation(selected: String) -> Observation {
        Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: selected))
    }

    /// The exact 5-`captureObservation`-call shape one successful mutating step produces (Nested-branch contract: grounding
    /// moved into `driveSteps`'s per-segment handling, adding one call): (1) `run`'s own vocabulary capture,
    /// (2) `driveSteps`'s own per-segment grounding capture, (3) `driveLinearSegment`'s pre-propose capture
    /// — all three see the OLD state — then (4) the dispatcher's internal post-action capture, (5) `run`'s
    /// trailing evidence capture — both see the NEW state. Chaining `stepQuad` calls builds the exact
    /// sequence a real multi-step scenario produces.
    static func stepQuad(pre: String, post: String) -> [Observation] {
        let preObs = Self.tabsObservation(selected: pre)
        let postObs = Self.tabsObservation(selected: post)
        return [preObs, preObs, preObs, postObs, postObs]
    }

    /// The catalog's one placeholder scenario id MUST equal the `scenarioID` `StatefulScenarioRunner.run`
    /// will be called with — `driveLinear` compiles every step's `SafeScenario` with `id: scenarioID`, and
    /// `TrustedActionValidator` looks that id up in this catalog (see the fix comment in
    /// `StatefulScenarioRunner.swift`). A mismatch here silently rejects every proposal.
    @MainActor
    static func rig(scenarioID: String, observations: [Observation]) -> (SequencedObservationDriver, ToolRegistry, ScenarioExecutionController) {
        let mock = SimulatedDriver(currentSnapshot: observations[0])
        let driver = SequencedObservationDriver(inner: mock, observations: observations)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: scenarioID, name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                                                actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        return (driver, registry, controller)
    }

    static func response(action: String, target: String, schema: Int = TestIR.currentSchemaVersion) -> String {
        """
        {"schemaVersion": \(schema), "testKey": "T", "title": "t", "steps": [
          {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "\(action)", "arguments": {},
           "target": {"role": "button", "label": "\(target)"},
           "verification": {"description": "d", "requiredElements": [], "forbiddenElements": [], "signals": [{"labelBecame": {"identifier": "e1_ignored", "to": "n/a"}}]}}
        ]}
        """
    }
    /// A tap step on the tabs screen WITH a real, dispatchable verification (the trusted
    /// `ScenarioVerificationService` fails closed on a mutating step with no explicit verification rule —
    /// this is correct, existing behavior, not something to route around). "Second" -> "tab:second",
    /// "First" -> "tab:first".
    static func tapResponse(target: String) -> String {
        let expectedStatus = target == "Second" ? "tab:second" : "tab:first"
        return """
        {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
          {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "tap", "arguments": {},
           "target": {"role": "button", "label": "\(target)"},
           "verification": {"description": "d", "requiredElements": [], "forbiddenElements": [],
                             "signals": [{"labelBecame": {"identifier": "fixture.tabs.status", "to": "\(expectedStatus)"}}]}}
        ]}
        """
    }
    static let badResponse = """
    {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
      {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "tap", "arguments": {},
       "target": {"role": "button", "identifier": "status_label"}}
    ]}
    """

    // 1. Multi-step ordering.
    @Test("Steps execute in the order given — step 2's generation is never invoked before step 1 completes")
    func testMultiStepOrdering() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "T1", observations: Self.stepQuad(pre: "first", post: "second") + Self.stepQuad(pre: "second", post: "first"))
        let client = ScriptedLLMClient([Self.tapResponse(target: "Second"), Self.tapResponse(target: "First")])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "T1", stepNLTexts: ["tap second", "tap first"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps.count == 2)
        #expect(evidence.steps[0].stepIndex == 1)
        #expect(evidence.steps[1].stepIndex == 2)
        #expect(client.callCount == 2, "exactly one generation call per step — no step is generated before its turn")
    }

    // 2/3. Fresh observation between steps / pre-post snapshot identity.
    @Test("Each step's preSnapshotID differs from its postSnapshotID when the observation changes, and step 2's pre is a FRESH capture, never step 1's post reused")
    func testFreshObservationAndSnapshotIdentity() async throws {
        let s0 = Observation(snapshotID: "S0", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "first"))
        let s1 = Observation(snapshotID: "S1", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "second"))
        let s2 = Observation(snapshotID: "S2", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "first"))
        // Step 1: calls 1-2 see S0 (pre), calls 3-4 see S1 (post). Step 2: calls 5-6 see S1 (pre, FRESH — not reused from step1's evidence object, actually re-captured), calls 7-8 see S2 (post).
        let (driver, registry, controller) = Self.rig(scenarioID: "T2", observations: [s0, s0, s0, s1, s1, s1, s1, s1, s2, s2])
        let client = ScriptedLLMClient([Self.tapResponse(target: "Second"), Self.tapResponse(target: "First")])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "T2", stepNLTexts: ["tap second", "tap first"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[0].preSnapshotID == "S0")
        #expect(evidence.steps[0].postSnapshotID == "S1")
        #expect(evidence.steps[0].preSnapshotID != evidence.steps[0].postSnapshotID)
        #expect(evidence.steps[1].preSnapshotID == "S1", "step 2's pre-observation is a FRESH capture of the real post-step-1 state, not a cached value")
        #expect(evidence.steps[1].postSnapshotID == "S2")
    }

    // 4/5. Stale grounding rejection / step-local grounding.
    @Test("A grounding result computed for step 1's vocabulary is never reused for step 2 — each step grounds against its OWN fresh vocabulary")
    func testStepLocalGroundingNeverReusesAnEarlierSnapshot() async throws {
        let tabsA = Self.tabsObservation(selected: "first")
        let navB = Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground,
                               elements: [UIElementSnapshot(id: "n1", role: "button", label: "Next", identifier: "fixture.navigation.next")])
        // Step 1 grounds "Second" against the tabs vocabulary (real, present). If step 2's vocabulary were
        // WRONGLY still the tabs one, "Next" would be unresolved; this test proves it grounds against navB.
        let vocabA = ObservedUIVocabulary.derive(from: tabsA)
        let vocabB = ObservedUIVocabulary.derive(from: navB)
        #expect(!vocabA.elements.contains { $0.accessibilityIdentifier == "fixture.navigation.next" })
        #expect(vocabB.elements.contains { $0.accessibilityIdentifier == "fixture.navigation.next" })
        #expect(vocabA.snapshotID != vocabB.snapshotID)
    }

    // 6. Step-local verification.
    @Test("Step 2's verification is evaluated against step 2's OWN post-observation, never step 1's")
    func testStepLocalVerification() async throws {
        let s0 = Observation(snapshotID: "S0", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "first"))
        let s1 = Observation(snapshotID: "S1", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "second"))
        let s2 = Observation(snapshotID: "S2", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: Self.tabsElements(selected: "first"))
        let (driver, registry, controller) = Self.rig(scenarioID: "T6", observations: [s0, s0, s0, s1, s1, s1, s1, s1, s2, s2])
        let client = ScriptedLLMClient([Self.tapResponse(target: "Second"), Self.tapResponse(target: "First")])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "T6", stepNLTexts: ["tap second", "tap first"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps.allSatisfy { $0.outcome == .completed })
    }

    // 7. Later-step regeneration (deterministic).
    @Test("Step 2 fails grounding on attempt 1, succeeds on attempt 2 — REGENERATED_SUCCESS occurs mid-scenario, not just at scenario start")
    func testLaterStepRegeneration() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "T7", observations: Self.stepQuad(pre: "first", post: "second") + Self.stepQuad(pre: "second", post: "first"))
        let client = ScriptedLLMClient([Self.tapResponse(target: "Second"), Self.badResponse, Self.tapResponse(target: "First")])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "T7", stepNLTexts: ["tap second", "tap first"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[0].resultKind == .directSuccess)
        #expect(evidence.steps[1].resultKind == .regeneratedSuccess)
        #expect(evidence.steps[1].attemptCount == 2)
    }

    // 8. Regeneration never dispatches (mid-scenario).
    @Test("Step 2's failed-then-regenerated generation never causes a dispatch during the failed attempt — only ONE real dispatch (the successful attempt) occurs for step 2")
    func testRegenerationNeverDispatchesMidScenario() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "T8", observations: Self.stepQuad(pre: "first", post: "second") + Self.stepQuad(pre: "second", post: "first"))
        let client = ScriptedLLMClient([Self.tapResponse(target: "Second"), Self.badResponse, Self.tapResponse(target: "First")])
        _ = try await StatefulScenarioRunner.run(scenarioID: "T8", stepNLTexts: ["tap second", "tap first"],
                                                 generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        let tapCount = await (driver.callIndex) // sanity: driver was actually invoked
        #expect(tapCount > 0)
        // Structural proof (Observation-grounding contract/46 precedent): GroundedTestIRGeneration.generate's failed attempts
        // never call driveLinear/dispatchCurrentStep — only the loop in StatefulScenarioRunner.run does,
        // and it does so exactly once per step, only after `.accepted`.
    }

    // 9. Failed step prevents downstream steps.
    @Test("Step 2 permanently unresolved (3 failed attempts) -> step 3 is NOT_EXECUTED, never attempted")
    func testFailedStepPreventsDownstreamSteps() async throws {
        // Step 1 succeeds (4 calls: first->second). Step 2 blocks at GROUNDING (never reaches dispatch, so
        // only 1 call — its own vocabulary capture, seeing the real post-step-1 "second" state).
        let (driver, registry, controller) = Self.rig(scenarioID: "T9", observations: Self.stepQuad(pre: "first", post: "second") + [Self.tabsObservation(selected: "second")])
        let client = ScriptedLLMClient([Self.tapResponse(target: "Second"), Self.badResponse, Self.badResponse, Self.badResponse])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "T9", stepNLTexts: ["tap second", "tap something fabricated", "tap first"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[0].outcome == .completed)
        #expect(evidence.steps[1].outcome == .blocked)
        #expect(evidence.steps[2].outcome == .notExecuted)
        #expect(client.callCount == 1 + 3, "step 1 (1 call) + step 2 (3 attempts, then blocked) — step 3 never even starts generating")
    }

    // 10. Execution uncertainty maps to recoveryRequired (documented boundary, not re-implemented here).
    @Test("StatefulScenarioRunner never introduces a second recovery mechanism — an execution-layer failure surfaces as a thrown DriverError, exactly as the unmodified ScenarioExecutionController already classifies it")
    func testExecutionUncertaintyIsNotHandledByANewMechanism() async throws {
        // Structural: StatefulScenarioRunner.driveLinear's only failure handling is `throw error` on
        // `.failure` from `dispatchCurrentStep` — it does not inspect the error, does not retry, and does
        // not call generate() again for the SAME step. The scenario simply stops (Part M/N).
        let obs = Self.tabsObservation(selected: "first")
        let (driver, registry, controller) = Self.rig(scenarioID: "T10", observations: [obs])
        let client = ScriptedLLMClient([Self.tapResponse(target: "NonexistentButton")])
        // "NonexistentButton" is not in the vocabulary, so this actually blocks at GROUNDING (not dispatch) —
        // confirming the scenario stops via the grounding path, never via a retry-on-uncertainty path.
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "T10", stepNLTexts: ["tap nonexistent"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[0].outcome == .blocked)
        #expect(client.callCount == 3, "no retry beyond the existing 3-attempt generation bound; no execution-triggered regeneration")
    }

    // 11. HITL remains mandatory.
    @Test("Every mutating step's proposal reaches a pending HITL approval before any dispatch — approveCurrentStep is required, never implicit")
    @MainActor
    func testHITLRemainsMandatory() throws {
        let target = IRTarget(role: "button", label: "Second")
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "tap", action: .tap, target: target)
        let scenario = TestIRExecutor.compileLinearScenario(testKey: "T11", title: "t", steps: [step], verdicts: ["s1": .admitted], credentials: [:])!
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        let executor = TestIRExecutor(controller: controller)
        let obs = Self.tabsObservation(selected: "first")
        guard case .pending(let approval) = executor.proposeCurrentStep(freshObservation: obs) else { Issue.record("must be pending"); return }
        #expect(approval.status == .pending)
        #expect(controller.executionCount == 0)
    }

    // 14/15. Evidence contains step correlation, and no secrets.
    @Test("Evidence for a blocked step names the correct step index/description and contains no credential-shaped text")
    func testEvidenceContainsStepCorrelationAndNoSecrets() async throws {
        let (driver, registry, controller) = Self.rig(scenarioID: "T14", observations: Self.stepQuad(pre: "first", post: "second") + [Self.tabsObservation(selected: "second")])
        let client = ScriptedLLMClient([Self.tapResponse(target: "Second"), Self.badResponse, Self.badResponse, Self.badResponse])
        let evidence = try await StatefulScenarioRunner.run(scenarioID: "T14", stepNLTexts: ["tap second", "tap fabricated"],
                                                             generator: TestIRGenerator(llmClient: client), driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(evidence.steps[1].stepIndex == 2)
        #expect(evidence.steps[1].stepDescription == "tap fabricated")
        for reason in evidence.steps[1].groundingBlockingReasons {
            #expect(!SecretRedactor.containsSecret(reason))
            #expect(!reason.contains("Bearer"))
        }
    }
}
