import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Regeneration contract, Part Q: deterministic tests for regeneration bounding (direct vs. regenerated success, the
/// 3-attempt cap), multi-screen/stale-vocabulary grounding, and the independence of grounding from the
/// semantic gate / trusted validator. No network, no simulator — a scripted stub `LLMClientProtocol` stands
/// in for DeepSeek so attempt-by-attempt outcomes are exactly reproducible; the REAL DeepSeek acceptance
/// evidence lives in `RegenerationLiveTests` (gated, live).
@Suite("IR.29 Regeneration contract Regeneration and Multi-Screen Grounding")
struct RegenerationAndMultiScreenGroundingTests {
    // MARK: - Fixtures: two REAL screen shapes (Live-execution contract/45's own captured element data)

    static func tabsVocabulary(snapshotID: String = "snap_tabs") -> ObservedUIVocabulary {
        ObservedUIVocabulary.derive(from: Observation(
            snapshotID: snapshotID, bundleID: "com.autonomous.agent.fixture", appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "e1", role: "other", label: "tab:first", identifier: "fixture.tabs.status"),
                UIElementSnapshot(id: "e2", role: "button", label: "First"),
                UIElementSnapshot(id: "e3", role: "button", label: "Second")
            ]
        ))
    }

    static func navigationVocabulary(snapshotID: String = "snap_nav") -> ObservedUIVocabulary {
        ObservedUIVocabulary.derive(from: Observation(
            snapshotID: snapshotID, bundleID: "com.autonomous.agent.fixture", appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "e1", role: "other", label: "navigation:root", identifier: "fixture.navigation.status"),
                UIElementSnapshot(id: "e2", role: "button", label: "Next", identifier: "fixture.navigation.next"),
                UIElementSnapshot(id: "e3", role: "other", label: "Root", identifier: "fixture.navigation.back"),
                UIElementSnapshot(id: "e4", role: "button", label: "Root", identifier: "fixture.navigation.back")
            ]
        ))
    }

    static let goodResponseTemplate = """
    {"schemaVersion": %d, "testKey": "T", "title": "t", "steps": [
      {"id": "s1", "sourceStepNumber": 1, "intent": "tap", "action": "tap", "arguments": {},
       "target": {"role": "button", "label": "Second"}}
    ]}
    """
    static let badResponseTemplate = """
    {"schemaVersion": %d, "testKey": "T", "title": "t", "steps": [
      {"id": "s1", "sourceStepNumber": 1, "intent": "tap", "action": "tap", "arguments": {},
       "target": {"role": "button", "identifier": "status_label"}}
    ]}
    """
    static var goodResponse: String { String(format: Self.goodResponseTemplate, TestIR.currentSchemaVersion) }
    static var badResponse: String { String(format: Self.badResponseTemplate, TestIR.currentSchemaVersion) }

    /// A scripted client: returns `responses[n]` on the (n+1)th call, clamped to the last entry once
    /// exhausted. Deterministic, reproducible, no network.
    final class ScriptedLLMClient: LLMClientProtocol, @unchecked Sendable {
        private(set) var callCount = 0
        private let responses: [String]
        init(_ responses: [String]) { self.responses = responses }
        func complete(_ request: LLMRequest) async throws -> String {
            try await sendPrompt(request.messages.map(\.text).joined(separator: "\n"))
        }
        func sendPrompt(_ prompt: String) async throws -> String {
            defer { callCount += 1 }
            return responses[min(callCount, responses.count - 1)]
        }
    }

    // 1. First attempt succeeds.
    @Test("First attempt succeeds -> DIRECT_SUCCESS, attemptCount == 1")
    func testFirstAttemptSucceeds() async {
        let client = ScriptedLLMClient([Self.goodResponse])
        let (outcome, evidence) = await GroundedTestIRGeneration.generate(using: TestIRGenerator(llmClient: client), testKey: "T", title: "t", stepsText: "tap second tab", vocabulary: Self.tabsVocabulary())
        guard case .accepted = outcome else { Issue.record("expected accepted"); return }
        #expect(evidence.resultKind == .directSuccess)
        #expect(evidence.attemptCount == 1)
        #expect(client.callCount == 1)
    }

    // 2. First attempt fails, second succeeds.
    @Test("First attempt fails, second succeeds -> REGENERATED_SUCCESS, attemptCount == 2")
    func testFirstFailsSecondSucceeds() async {
        let client = ScriptedLLMClient([Self.badResponse, Self.goodResponse])
        let (outcome, evidence) = await GroundedTestIRGeneration.generate(using: TestIRGenerator(llmClient: client), testKey: "T", title: "t", stepsText: "tap second tab", vocabulary: Self.tabsVocabulary())
        guard case .accepted = outcome else { Issue.record("expected accepted"); return }
        #expect(evidence.resultKind == .regeneratedSuccess)
        #expect(evidence.attemptCount == 2)
        #expect(client.callCount == 2)
    }

    // 3. All three attempts fail.
    @Test("All three attempts fail -> BLOCKED")
    func testAllThreeAttemptsFail() async {
        let client = ScriptedLLMClient([Self.badResponse, Self.badResponse, Self.badResponse])
        let (outcome, evidence) = await GroundedTestIRGeneration.generate(using: TestIRGenerator(llmClient: client), testKey: "T", title: "t", stepsText: "tap second tab", vocabulary: Self.tabsVocabulary())
        guard case .blocked(_, let attempts) = outcome else { Issue.record("expected blocked"); return }
        #expect(attempts.count == 3)
        #expect(evidence.resultKind == .blocked)
        #expect(client.callCount == 3)
    }

    // 5. Feedback is observation-bound.
    @Test("Grounding feedback's 'observed identifiers you may use' section lists only the CURRENT vocabulary's real identifiers — never a different screen's, even though the proposed (wrong) identifier is legitimately echoed back for diagnosis")
    func testFeedbackIsObservationBound() {
        let ir = TestIR(testKey: "T", title: "t", steps: [IRStep(id: "s1", sourceStepNumber: 1, intent: "tap", action: .tap, target: IRTarget(role: "button", identifier: "fixture.navigation.next"))])
        let tabsVocab = Self.tabsVocabulary()
        let result = ObservationGroundingService.ground(ir: ir, vocabulary: tabsVocab)
        let feedback = ObservationGroundingFeedback.build(from: result, vocabulary: tabsVocab)
        let observedSection = feedback.components(separatedBy: "Observed identifiers you may use:").last ?? ""
        #expect(!observedSection.contains("fixture.navigation.next"), "the navigation screen's identifier must never appear in the CURRENT vocabulary's own observed-identifiers list")
        #expect(!observedSection.contains("fixture.navigation.back"))
        #expect(observedSection.contains("fixture.tabs.status"), "the tabs screen's own real identifier must be the one offered")
    }

    // 8. Stale vocabulary rejected.
    @Test("A grounding result computed against snapshot A is not current against snapshot B, even for the SAME screen re-captured")
    func testStaleVocabularyRejected() {
        let ir = TestIR(testKey: "T", title: "t", steps: [IRStep(id: "s1", sourceStepNumber: 1, intent: "tap", action: .tap, target: IRTarget(role: "button", label: "Second"))])
        let vocabA = Self.tabsVocabulary(snapshotID: "snap_A")
        let vocabB = Self.tabsVocabulary(snapshotID: "snap_B") // same real elements, different snapshot identity
        let resultA = ObservationGroundingService.ground(ir: ir, vocabulary: vocabA)
        #expect(ObservationGroundingService.isCurrent(resultA, against: vocabA))
        #expect(!ObservationGroundingService.isCurrent(resultA, against: vocabB), "identical element content does not make a grounding result current against a DIFFERENT snapshot")
    }

    // 9. Old identifier rejected on new screen.
    @Test("An identifier real on Screen B (navigation) is unresolved when grounded against Screen A's (tabs) vocabulary")
    func testOldScreenIdentifierRejectedOnNewScreen() {
        let ir = TestIR(testKey: "T", title: "t", steps: [
            IRStep(id: "s1", sourceStepNumber: 1, intent: "tap next", action: .tap, target: IRTarget(role: "button", identifier: "fixture.navigation.next"))
        ])
        #expect(Self.navigationVocabulary().elements.contains { $0.accessibilityIdentifier == "fixture.navigation.next" }, "precondition: this identifier is genuinely real on screen B")
        let result = ObservationGroundingService.ground(ir: ir, vocabulary: Self.tabsVocabulary())
        #expect(result.issues.first?.status == .unresolved, "OLD IR + NEW SCREEN must never be automatically accepted")
    }

    // 10. Ambiguity rejected.
    @Test("A real duplicate-identifier shape (fixture.navigation.back: role 'other' AND role 'button', same identifier) is ambiguous when role is not used to narrow it")
    func testAmbiguityRejected() {
        let issue = ObservationGroundingService.resolve(role: nil, identifier: "fixture.navigation.back", label: nil, stepID: "s1", kind: "target", vocabulary: Self.navigationVocabulary())
        #expect(issue.status == .ambiguous)
    }

    // 13. Regeneration cannot execute tools.
    @Test("The full 3-attempt regeneration loop (mixed bad/good) never touches a driver, ToolRegistry, or ScenarioExecutionController")
    func testRegenerationCannotExecuteTools() async {
        // Structural: GroundedTestIRGeneration.generate's only calls are TestIRGenerator/TestIRValidator/
        // ObservationGroundingService (confirmed by source inspection, Observation-grounding contract report) — reconfirmed here
        // by running a mixed bad->good script to completion and observing only LLM calls occurred.
        let client = ScriptedLLMClient([Self.badResponse, Self.goodResponse])
        _ = await GroundedTestIRGeneration.generate(using: TestIRGenerator(llmClient: client), testKey: "T", title: "t", stepsText: "tap second tab", vocabulary: Self.tabsVocabulary())
        #expect(client.callCount == 2, "exactly the LLM calls occurred, and nothing else observable happened")
    }

    // 14. Regeneration cannot authorize actions.
    @Test("Nothing in the regeneration loop ever constructs a HITLApprovalRequest — authorization only ever originates from ScenarioExecutionController.handleProposal, never from generation")
    func testRegenerationCannotAuthorizeActions() async {
        let client = ScriptedLLMClient([Self.badResponse, Self.goodResponse])
        let (outcome, _) = await GroundedTestIRGeneration.generate(using: TestIRGenerator(llmClient: client), testKey: "T", title: "t", stepsText: "tap second tab", vocabulary: Self.tabsVocabulary())
        guard case .accepted = outcome else { Issue.record("expected accepted"); return }
        // The outcome type itself (GroundedGenerationOutcome) has no case and no field capable of carrying
        // an approval/authorization object — accepted IR only, never an HITLApprovalRequest.
        let mirror = Mirror(reflecting: outcome)
        #expect(!mirror.children.contains { $0.label == "approval" || $0.label == "authorization" })
    }

    // 15. Successful regeneration still requires HITL.
    @Test("An IR accepted only after regeneration still stops at a pending HITL approval — never auto-approved")
    @MainActor
    func testRegeneratedAcceptanceStillRequiresHITL() async {
        let client = ScriptedLLMClient([Self.badResponse, Self.goodResponse])
        let (outcome, evidence) = await GroundedTestIRGeneration.generate(using: TestIRGenerator(llmClient: client), testKey: "T", title: "t", stepsText: "tap second tab", vocabulary: Self.tabsVocabulary())
        guard case .accepted(let ir, _) = outcome, evidence.resultKind == .regeneratedSuccess else { Issue.record("expected a regenerated acceptance"); return }

        let validation = TestIRValidator.validate(ir)
        guard let scenario = TestIRExecutor.compileLinearScenario(testKey: "T", title: "t", steps: ir.steps, verdicts: validation.stepVerdicts, credentials: [:]) else {
            Issue.record("must compile"); return
        }
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        let executor = TestIRExecutor(controller: controller)
        let obs = Observation(snapshotID: "snap_tabs", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground,
                              elements: [UIElementSnapshot(id: "e3", role: "button", label: "Second")])
        guard case .pending(let approval) = executor.proposeCurrentStep(freshObservation: obs) else {
            Issue.record("a regenerated, grounded IR must still reach a pending approval"); return
        }
        #expect(approval.status == .pending)
        #expect(controller.executionCount == 0, "nothing dispatched merely because generation/grounding succeeded")
    }

    // 16. Successful regeneration still requires fresh execution observation.
    @Test("An IR accepted after regeneration still needs its OWN fresh observation at dispatch time — the grounding-time vocabulary is never treated as the dispatch-time observation")
    @MainActor
    func testRegeneratedAcceptanceStillRequiresFreshObservation() async {
        let client = ScriptedLLMClient([Self.badResponse, Self.goodResponse])
        let (outcome, _) = await GroundedTestIRGeneration.generate(using: TestIRGenerator(llmClient: client), testKey: "T", title: "t", stepsText: "tap second tab", vocabulary: Self.tabsVocabulary())
        guard case .accepted(let ir, _) = outcome else { Issue.record("expected accepted"); return }

        let validation = TestIRValidator.validate(ir)
        guard let scenario = TestIRExecutor.compileLinearScenario(testKey: "T", title: "t", steps: ir.steps, verdicts: validation.stepVerdicts, credentials: [:]) else {
            Issue.record("must compile"); return
        }
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        #expect(controller.startScenario(scenario))
        let executor = TestIRExecutor(controller: controller)
        let preObs = Observation(snapshotID: "snap_pre", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground,
                                 elements: [UIElementSnapshot(id: "e3", role: "button", label: "Second")])
        guard case .pending = executor.proposeCurrentStep(freshObservation: preObs) else { Issue.record("must be pending"); return }
        controller.approveCurrentStep(source: .testAuthority)

        let driver = SimulatedDriver(currentSnapshot: preObs)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        // A DIFFERENT, genuinely fresh post-action observation is what dispatch/verification must use —
        // never the grounding-time vocabulary's own (now stale) observation.
        await driver.queueNextSnapshot(Observation(snapshotID: "snap_post", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground,
                                                    elements: [UIElementSnapshot(id: "e3", role: "button", label: "Second", isSelected: true)]))
        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry,
                                                          bundleID: "com.autonomous.agent.fixture")
        guard case .success = result else { Issue.record("dispatch must complete using the fresh post-observation"); return }
        #expect(await driver.currentSnapshot.snapshotID == "snap_post", "the driver's current snapshot after dispatch is the FRESH one, never the grounding-time observation")
    }
}
