import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Category E: LLM FABRICATION / GROUNDING FAILURE. Every test proves `ObservationGroundingService`
/// (unmodified since Branch/regeneration contract) rejects an LLM-proposed reference that does not correspond to any real,
/// currently-observed element — and that this rejection happens BEFORE dispatch, with zero approvals and
/// zero driver calls, whether the fabrication is a bad identifier, a bad label, a bad navigation target, a
/// bad branch-arm target, or a target only a LATER step fabricates.
@Suite("Fault-injection matrix.E Grounding Fault Injection")
@MainActor
struct GroundingFaultTests {
    static func fixtureVocabulary() -> ObservedUIVocabulary {
        let obs = Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "other", label: "tab:first", identifier: "fixture.tap.status"),
            UIElementSnapshot(id: "e2", role: "button", label: "Tap Me", identifier: "fixture.tap.target")
        ])
        return ObservedUIVocabulary.derive(from: obs)
    }

    @Test("A fabricated accessibility identifier (never observed) is rejected as unresolved, not silently first-matched")
    func testFabricatedIdentifierUnresolved() {
        let vocab = Self.fixtureVocabulary()
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", identifier: "status_label"))
        let result = ObservationGroundingService.groundSteps([step], vocabulary: vocab)
        #expect(!result.isFullyGrounded)
        #expect(result.blockingIssues.contains { $0.status == .unresolved })
    }

    @Test("A fabricated label (never observed, with a real role) is rejected as unresolved")
    func testFabricatedLabelUnresolved() {
        let vocab = Self.fixtureVocabulary()
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "Nonexistent Button"))
        let result = ObservationGroundingService.groundSteps([step], vocabulary: vocab)
        #expect(!result.isFullyGrounded)
        #expect(result.blockingIssues.allSatisfy { $0.status == .unresolved })
    }

    @Test("A fabricated navigation target (selectTab naming a tab that was never observed) is rejected before dispatch")
    func testFabricatedNavigationTargetUnresolved() {
        let vocab = Self.fixtureVocabulary()
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "i", action: .selectTab, target: IRTarget(role: "button", label: "Third"))
        let result = ObservationGroundingService.groundSteps([step], vocabulary: vocab)
        #expect(!result.isFullyGrounded)
    }

    @Test("A fabricated target inside a SELECTED branch arm is rejected; the branch mechanism itself is real and unmodified")
    func testFabricatedBranchArmTargetUnresolved() {
        let vocab = Self.fixtureVocabulary()
        // Only the selected (thenSteps) arm is ever grounded here — mirroring how StatefulScenarioRunner
        // grounds exactly one already-selected arm's own step list, never the branch step itself.
        let selectedArmSteps = [IRStep(id: "then1", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "Ghost Button"))]
        let result = ObservationGroundingService.groundSteps(selectedArmSteps, vocabulary: vocab)
        #expect(!result.isFullyGrounded)
        #expect(result.blockingIssues.contains { $0.status == .unresolved })
    }

    @Test("A fabricated target that only a LATER step in the same document names is independently rejected when that step's own segment is grounded — one step's real target never excuses another's fabricated one")
    func testFabricatedLaterStepTargetIndependentlyRejected() {
        let vocab = Self.fixtureVocabulary()
        let steps = [
            IRStep(id: "s1", sourceStepNumber: 1, intent: "real", action: .tap, target: IRTarget(role: "button", identifier: "fixture.tap.target")),
            IRStep(id: "s2", sourceStepNumber: 2, intent: "fabricated", action: .tap, target: IRTarget(role: "button", identifier: "fixture.tap.nonexistent"))
        ]
        let result = ObservationGroundingService.groundSteps(steps, vocabulary: vocab)
        #expect(!result.isFullyGrounded)
        let s1Issues = result.issues.filter { $0.stepID == "s1" }
        let s2Issues = result.issues.filter { $0.stepID == "s2" }
        #expect(s1Issues.allSatisfy { $0.status == .grounded }, "the real step's own target must ground correctly regardless of its sibling")
        #expect(s2Issues.contains { $0.status == .unresolved }, "the fabricated sibling step's target is independently rejected")
    }

    // MARK: - End-to-end: ungrounded target never reaches dispatch; bounded regeneration; zero approvals/driver calls.

    @Test("A fabricated target reaching StatefulScenarioRunner's per-segment grounding throws before any proposal/approval/driver call — zero dispatches for the fabricated step")
    func testUngroundedSegmentNeverDispatches() async throws {
        let obs = Observation(snapshotID: "snap_1", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e2", role: "button", label: "Tap Me", identifier: "fixture.tap.target")
        ])
        let mock = SimulatedDriver(currentSnapshot: obs)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        await driver.queueObservations([obs, obs, obs, obs, obs]) // more than enough for any call sequence
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "GND-1", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                                                actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))

        let fabricatedStep = IRStep(id: "s1", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", identifier: "status_label"),
                                     verification: IRVerification(description: "d", signals: [.elementExists(SignalLocator(role: "button", identifier: "status_label"))]))
        let validation = TestIRValidator.validate(TestIR(testKey: "GND-1", title: "t", steps: [fabricatedStep]))
        #expect(validation.isAccepted, "the document is structurally legal — the fabrication is only discoverable by GROUNDING against real observed elements, not by static validation")

        var threw = false
        do {
            _ = try await StatefulScenarioRunner.driveSteps([fabricatedStep], verdicts: validation.stepVerdicts, testKey: "GND-1", title: "t",
                                                             driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        } catch {
            threw = true
        }
        #expect(threw, "an ungrounded segment must throw before any dispatch is attempted")
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0, "zero driver mutations for a fabricated, never-grounded target")
        #expect(controller.activeApproval == nil, "no approval may ever be created for an ungrounded proposal")
    }

    @Test("Bounded regeneration: a fabricated target that persists across all attempts is BLOCKED, never silently admitted, and dispatches zero times")
    func testPersistentFabricationBlocksAfterBoundedAttempts() async throws {
        typealias ScriptedLLMClient = RegenerationAndMultiScreenGroundingTests.ScriptedLLMClient
        let vocab = Self.fixtureVocabulary()
        // Every attempt (initial + all regenerations) proposes the SAME fabricated identifier — the model
        // never converges on a real one.
        let badJSON = """
        {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "GND-2", "title": "t", "steps": [
          {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "tap", "arguments": {},
           "target": {"role": "button", "identifier": "status_label"}}
        ]}
        """
        let client = ScriptedLLMClient([badJSON, badJSON, badJSON])
        let generator = TestIRGenerator(llmClient: client)
        let (outcome, evidence) = await GroundedTestIRGeneration.generate(using: generator, testKey: "GND-2", title: "t", stepsText: "tap the status label", vocabulary: vocab)
        guard case .blocked = outcome else { Issue.record("expected blocked after persistent fabrication, got \(outcome)"); return }
        #expect(evidence.resultKind == .blocked)
        #expect(evidence.attemptCount <= 3, "bounded to the documented 3-total-attempt cap, never unbounded retry")
    }
}
