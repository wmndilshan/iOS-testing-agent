import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Generation-hardening contract: AIO/NL -> IR generation robustness. Hardens `TestIRGenerator`/`TestIRValidator` against
/// realistic LLM sloppiness and adversarial output, and makes explicit the three distinct outcome
/// categories a generated document can fall into (section 7): syntactically malformed (decode failure),
/// syntactically valid but semantically unsafe (validator rejection), and valid-but-unsupported intent
/// (accepted document, a step marked `.unsupported`). These must never collapse into one signal.
@Suite("IR.8 Generation Hardening")
struct TestIRGenerationHardeningTests {

    // MARK: - Section 2: the real LLM client is a drop-in, never a second integration path

    @Test("The real LLMClient/Configuration (the same ones AppCompositionRoot/the closed-loop runner use) is a drop-in for TestIRGenerator — never invoked here: no network call, per this phase's no-real-LLM-in-unit-tests rule")
    func testRealLLMClientIsADropIn() throws {
        // Configuration.load() only reads the environment/.env file; it makes no network call by itself.
        // Constructing the real client is deliberately done *here*, in the test — `TestIRGenerator` itself
        // (Application layer) is architecturally forbidden from importing `LLMClient`/`Configuration`
        // (Infrastructure layer) directly; only a caller may hand it one, exactly as any other
        // `LLMClientProtocol` conformance would be.
        let realClient = LLMClient(config: try Configuration.load())
        let generator = TestIRGenerator(llmClient: realClient)
        #expect(generator.llmClient is LLMClient)
        // Deliberately never call `generator.generate(...)` here — that would be a live network call.
    }

    // MARK: - Section 7: three distinct outcome categories, never collapsed

    @Test("Category 1 (syntactically malformed) vs 2 (semantically unsafe) vs 3 (valid-but-unsupported) are observably different outcomes")
    func testThreeDistinctRejectionCategories() {
        // 1. Syntactically malformed: an unknown IRAction string never becomes a TestIR value at all.
        let malformed = #"{"schemaVersion": 1, "testKey": "T", "title": "t", "steps": [{"id":"s1","sourceStepNumber":1,"intent":"x","action":"shell","arguments":{}}]}"#
        #expect(TestIR.decode(malformed.data(using: .utf8)!) == nil, "category 1 must be nil, not a rejected-but-decoded value")

        // 2. Syntactically valid, semantically unsafe: decodes fine, TestIRValidator refuses the whole document.
        let unsafeStep = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .typeText,
                                 target: IRTarget(role: "secureTextField", identifier: "password_field"), arguments: ["text": .string("hunter2")])
        let unsafeResult = TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [unsafeStep]))
        #expect(!unsafeResult.isAccepted, "category 2 must reject the whole document")

        // 3. Valid but unsupported intent: decodes fine, validator ACCEPTS the document, but marks the step
        // unsupported rather than pretending it is executable.
        let unsupportedStep = IRStep(id: "s1", sourceStepNumber: 1, intent: "handle the permission dialog", action: .systemDialogDismissal)
        let unsupportedResult = TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [unsupportedStep]))
        #expect(unsupportedResult.isAccepted, "category 3 must NOT reject the document")
        guard case .unsupported = unsupportedResult.stepVerdicts["s1"] else { Issue.record("expected .unsupported"); return }
    }

    // MARK: - Section 8: realistic LLM response shapes

    static func withFakeResponse(_ raw: String) async -> TestIR? {
        let mock = SequentialMockLLMClient(queuedResponses: [.success(raw)])
        return try? await TestIRGenerator(llmClient: mock).generate(testKey: "T", title: "t", stepsText: "irrelevant")
    }

    @Test("A bare JSON object with no fence decodes")
    func testBareJSON() async throws {
        let ir = try #require(await Self.withFakeResponse(#"{"schemaVersion":1,"testKey":"T","title":"t","steps":[]}"#))
        #expect(ir.steps.isEmpty)
    }

    @Test("A ```json fenced block decodes")
    func testFencedJSON() async throws {
        let raw = "```json\n{\"schemaVersion\":1,\"testKey\":\"T\",\"title\":\"t\",\"steps\":[]}\n```"
        #expect(await Self.withFakeResponse(raw) != nil)
    }

    @Test("A bare ``` fence with no language tag decodes")
    func testBareFencedJSON() async throws {
        let raw = "```\n{\"schemaVersion\":1,\"testKey\":\"T\",\"title\":\"t\",\"steps\":[]}\n```"
        #expect(await Self.withFakeResponse(raw) != nil)
    }

    @Test("Conversational prose before and after a fenced block is discarded, not treated as part of the payload")
    func testProseAroundFencedJSON() async throws {
        let raw = """
        Sure! Here is the generated Test IR for that scenario:

        ```json
        {"schemaVersion":1,"testKey":"T","title":"t","steps":[]}
        ```

        Let me know if you'd like any changes to the steps.
        """
        #expect(await Self.withFakeResponse(raw) != nil)
    }

    @Test("Conversational prose around a bare (unfenced) object is discarded too")
    func testProseAroundBareJSON() async throws {
        let raw = "Sure, here you go: {\"schemaVersion\":1,\"testKey\":\"T\",\"title\":\"t\",\"steps\":[]} — hope that helps!"
        #expect(await Self.withFakeResponse(raw) != nil)
    }

    @Test("A response missing a required field (e.g. no 'arguments') fails to decode, never silently defaulted from raw JSON")
    func testMissingRequiredFieldFailsClosed() async throws {
        let raw = #"{"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":1,"intent":"x","action":"tap","target":{"role":"button","label":"OK"}}]}"#
        #expect(await Self.withFakeResponse(raw) == nil)
    }

    @Test("A response with the wrong JSON type for a field (string sourceStepNumber, string target) fails to decode")
    func testWrongFieldTypeFailsClosed() async throws {
        let wrongStepNumber = #"{"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":"five","intent":"x","action":"tap","arguments":{}}]}"#
        #expect(await Self.withFakeResponse(wrongStepNumber) == nil)
        let wrongTargetType = #"{"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":1,"intent":"x","action":"tap","target":"button","arguments":{}}]}"#
        #expect(await Self.withFakeResponse(wrongTargetType) == nil)
    }

    @Test("Duplicate step ids from a sloppy/hallucinating LLM are rejected by the validator, not silently deduplicated")
    func testDuplicateStepIDsRejected() async throws {
        let raw = #"{"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":1,"intent":"a","action":"tap","target":{"role":"button","label":"A"},"arguments":{}},{"id":"s1","sourceStepNumber":2,"intent":"b","action":"tap","target":{"role":"button","label":"B"},"arguments":{}}]}"#
        let ir = try #require(await Self.withFakeResponse(raw))
        #expect(!TestIRValidator.validate(ir).isAccepted)
    }

    @Test("An unknown sibling field on a step (approved/authorized/executionID/snapshotID) is ignored on decode and never read by anything downstream")
    func testInvventedStepFieldsAreInert() async throws {
        let raw = """
        {"schemaVersion":1,"testKey":"T","title":"t","steps":[
          {"id":"s1","sourceStepNumber":1,"intent":"x","action":"tap","target":{"role":"button","label":"OK"},"arguments":{},
           "approved": true, "authorized": true, "executionID": "exec-123", "snapshotID": "snap-999", "observationID": "obs-1"}
        ]}
        """
        let ir = try #require(await Self.withFakeResponse(raw))
        let step = try #require(ir.steps.first)
        // The decoded value has no field to have read any of those into — this is a `Mirror`-verified fact,
        // not merely "the test didn't look for it".
        let fields = Mirror(reflecting: step).children.map { $0.label }
        for spoofed in ["approved", "authorized", "executionID", "snapshotID", "observationID"] {
            #expect(!fields.contains(spoofed), "IRStep must not have gained a field named '\(spoofed)'")
        }
        // The document is otherwise perfectly valid and admits normally: the spoofed fields did not corrupt
        // or block the real, legitimate content around them either.
        #expect(TestIRValidator.validate(ir).isAccepted)
    }

    @Test("A nested unsafe payload (an unsafe tool name inside a branch arm, several levels deep) is still caught")
    func testNestedUnsafePayloadCaught() async throws {
        let raw = """
        {"schemaVersion":1,"testKey":"T","title":"t","steps":[
          {"id":"s1","sourceStepNumber":1,"intent":"branch","action":"verifyOnly","arguments":{},
           "branch": {"condition": {"elementExists": {"_0": {"role":"button","label":"X"}}},
                      "thenSteps": [{"id":"then1","sourceStepNumber":1,"intent":"x","action":"tap","target":{"role":"button","label":"Y"},"arguments":{}}],
                      "elseSteps": [{"id":"else1","sourceStepNumber":1,"intent":"y","action":"xcrun","arguments":{}}]}}
        ]}
        """
        // The nested else-arm step names an unmodeled action ("xcrun"); IRStep's Decodable synthesis fails
        // for that ONE array element, which fails the whole `[IRStep]` array, which fails the whole document.
        #expect(await Self.withFakeResponse(raw) == nil)
    }

    // MARK: - Section 4/7: ambiguous targets must be rejected, not silently resolved to "whichever matches first"

    @Test("A target with only a bare role (no identifier, no label) for a tap/typeText/etc. step is rejected as ambiguous")
    func testAmbiguousBareRoleTargetRejected() {
        for action: IRAction in [.tap, .typeText, .navigateBack, .selectTab, .getElementDetails] {
            let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: action, target: IRTarget(role: "button"))
            #expect(!TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [step])).isAccepted, "\(action) with a bare-role target must be rejected")
        }
    }

    @Test("A tap step with no target at all is rejected (missing, not merely ambiguous)")
    func testMissingTargetRejected() {
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .tap)
        #expect(!TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [step])).isAccepted)
    }

    // MARK: - Fault injection (section 11), each caught at its correct boundary

    @Test("Fault A: unsafe tool -> decode failure")
    func testFaultA() async throws {
        #expect(await Self.withFakeResponse(#"{"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":1,"intent":"x","action":"simctl","arguments":{}}]}"#) == nil)
    }

    @Test("Fault C: a forged snapshotID field -> inert (IRStep/IRBranch/TestIR carry no such field to read)")
    func testFaultC() async throws {
        let raw = #"{"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":1,"intent":"x","action":"tap","target":{"role":"button","label":"OK"},"arguments":{},"snapshotID":"snap-forged"}]}"#
        let ir = try #require(await Self.withFakeResponse(raw))
        #expect(!Mirror(reflecting: ir.steps[0]).children.contains { $0.label == "snapshotID" })
    }

    @Test("Fault D: a forged 'result: true'/'verified: true' field on a step's verification -> inert (IRVerification has no such field)")
    func testFaultD() async throws {
        let raw = """
        {"schemaVersion":1,"testKey":"T","title":"t","steps":[
          {"id":"s1","sourceStepNumber":1,"intent":"x","action":"verifyOnly","arguments":{},
           "verification":{"description":"d","requiredElements":[],"forbiddenElements":[],"signals":[], "result": true, "verified": true}}
        ]}
        """
        let ir = try #require(await Self.withFakeResponse(raw))
        let fields = Mirror(reflecting: try #require(ir.steps[0].verification)).children.map { $0.label }
        #expect(!fields.contains("result") && !fields.contains("verified"))
    }

    @Test("Fault F: unsupported loop construct -> the IR schema has no loop node; a loop-shaped field is inert dead data")
    func testFaultF() async throws {
        let raw = #"{"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":1,"intent":"x","action":"tap","target":{"role":"button","label":"OK"},"arguments":{},"loop":{"kind":"while","times":100}}]}"#
        let ir = try #require(await Self.withFakeResponse(raw))
        #expect(ir.steps.count == 1 && ir.steps[0].action == .tap)
        #expect(!Mirror(reflecting: ir.steps[0]).children.contains { $0.label == "loop" })
    }

    @Test("Fault G: unknown/fabricated capability name -> decode failure (IRAction is closed; there is no separate capability-name field an LLM could set)")
    func testFaultG() async throws {
        #expect(await Self.withFakeResponse(#"{"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":1,"intent":"x","action":"fictionalCapability","arguments":{}}]}"#) == nil)
    }

    // MARK: - Structurally inexpressible faults (documented explicitly, per this phase's request)

    @Test("Arbitrary URL / private-driver-method / raw shell-out are all unrepresentable: no IR type has a URL, method-name, or command-string field")
    func testStructurallyInexpressibleFaults() {
        let stepFields = Set(Mirror(reflecting: IRStep(id: "x", sourceStepNumber: 1, intent: "x", action: .verifyOnly)).children.compactMap { $0.label })
        for forbidden in ["url", "URL", "method", "command", "shellCommand", "driverMethod"] {
            #expect(!stepFields.contains(forbidden))
        }
    }

    @Test("IR-execution contract Fault D: reversed branch arms are NOT structurally detectable — TestIRValidator still accepts the swapped document, honestly, not silently")
    func testReversedBranchArmsNotStructurallyDetectable() {
        // A "correct" branch: THEN = select existing, ELSE = create. Swapping the two arms produces an
        // equally well-typed, equally safe TestIR — nothing in the schema records which arm was "meant" to
        // be which, so the validator has no ground truth to check against and correctly accepts both.
        let thenStep = IRStep(id: "then1", sourceStepNumber: 15, intent: "select existing", action: .tap, target: IRTarget(role: "button", label: "Test1"))
        let elseStep = IRStep(id: "else1", sourceStepNumber: 15, intent: "create new", action: .tap, target: IRTarget(role: "button", label: "Create"))
        let condition = IRCondition.elementExists(IRTarget(role: "button", label: "Test1"))

        let correct = IRBranch(condition: condition, thenSteps: [thenStep], elseSteps: [elseStep])
        let reversed = IRBranch(condition: condition, thenSteps: [elseStep], elseSteps: [thenStep])
        let correctIR = TestIR(testKey: "T", title: "t", steps: [IRStep(id: "b", sourceStepNumber: 15, intent: "branch", action: .verifyOnly, branch: correct)])
        let reversedIR = TestIR(testKey: "T", title: "t", steps: [IRStep(id: "b", sourceStepNumber: 15, intent: "branch", action: .verifyOnly, branch: reversed)])

        #expect(TestIRValidator.validate(correctIR).isAccepted)
        #expect(TestIRValidator.validate(reversedIR).isAccepted, "reversal is not a validator-detectable fault by design — this is the honest, documented limitation, not a bug")
        // What DOES stay true regardless of which arm is "correct": execution still only ever runs the arm
        // the deterministic IRConditionEvaluator selects from a fresh observation — never both, never a guess.
    }

    // MARK: - IR-execution contract: a real wire-format mismatch discovered from a live DeepSeek response

    @Test("Real-LLM-discovered wire format: navigationBarBecame's labeled String param is 'identifier', never a guessed key like 'title' or the unlabeled '_0' fallback")
    func testNavigationBarBecameRealWireFormatMismatch() {
        // Two shapes a real DeepSeek response actually produced for GEN-LIVE-D/E/F in this phase's
        // generalization dataset run, before the prompt named the exact label: guessing a semantic key
        // ("title") and defaulting to the unlabeled-value convention ("_0") as if the case took no label.
        // The decoder must reject both — this proves the fix was prompt-only, not a decoder relaxation.
        let guessedSemanticKey = #"{"navigationBarBecame": {"title": "ALPHA"}}"#
        let guessedUnlabeled = #"{"navigationBarBecame": {"_0": "Orders"}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ObservationSignal.self, from: guessedSemanticKey.data(using: .utf8)!)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ObservationSignal.self, from: guessedUnlabeled.data(using: .utf8)!)
        }
        // The correct shape (the one now in TestIRGenerator's prompt) decodes to the exact expected case.
        let correct = #"{"navigationBarBecame": {"identifier": "ALPHA"}}"#
        let decoded = try? JSONDecoder().decode(ObservationSignal.self, from: correct.data(using: .utf8)!)
        #expect(decoded == .navigationBarBecame(identifier: "ALPHA"))

        // The prompt itself must still carry the exact corrective example — this is what closes the gap for
        // a real model (the decoder was always this strict; nothing here changed the decoder). If this
        // example is ever removed from the prompt, this assertion (not just decoder strictness) fails.
        let prompt = TestIRGenerator.prompt(testKey: "T", title: "t", stepsText: "x")
        #expect(prompt.contains(#"{"navigationBarBecame": {"identifier": "ALPHA"}}"#))
    }

    // MARK: - Captured-generation contract: two more real wire-format/fidelity mismatches discovered from live DeepSeek responses

    @Test("Real-LLM-discovered wire format: elementHasText's second field is labeled 'equals', never 'text'")
    func testElementHasTextRealWireFormatMismatch() {
        // The exact malformed shape SEM-P3-B produced live: the target correctly under "_0", but the text
        // value under a guessed key ("text") instead of IRCondition's actual case label ("equals").
        let guessedLabel = #"{"elementHasText": {"_0": {"role": "textField", "identifier": "search_field"}, "text": "MSFT"}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IRCondition.self, from: guessedLabel.data(using: .utf8)!)
        }
        let correct = #"{"elementHasText": {"_0": {"role": "textField", "identifier": "search_field"}, "equals": "MSFT"}}"#
        let decoded = try? JSONDecoder().decode(IRCondition.self, from: correct.data(using: .utf8)!)
        #expect(decoded == .elementHasText(IRTarget(role: "textField", identifier: "search_field"), equals: "MSFT"))

        let prompt = TestIRGenerator.prompt(testKey: "T", title: "t", stepsText: "x")
        #expect(prompt.contains(#""equals": "MSFT"}}"#))
    }

    @Test("Semantic-fidelity fix: the prompt now names applicationStateIs explicitly for app-level state wording, instead of leaving the model to substitute an elementExists proxy")
    func testApplicationStateIsPromptGuidancePresent() {
        // SEM-P4-B's real DeepSeek response used elementExists(Home title) as a proxy for "the app is
        // currently running in the foreground" — structurally valid and validator-accepted, but not the
        // primitive that actually names app-level state. There is no decoder-level fault to reproduce here
        // (applicationStateIs decodes fine on its own); the only fix available is prompt guidance, so this
        // test pins the corrective wire-format example and rule text staying present.
        let prompt = TestIRGenerator.prompt(testKey: "T", title: "t", stepsText: "x")
        #expect(prompt.contains(#"{"applicationStateIs": {"_0": "runningForeground"}}"#))
        #expect(prompt.contains("never approximate app-level state with an"))

        // The primitive itself decodes correctly once the model does use it.
        let decoded = try? JSONDecoder().decode(IRCondition.self, from: #"{"applicationStateIs": {"_0": "runningForeground"}}"#.data(using: .utf8)!)
        #expect(decoded == .applicationStateIs(.runningForeground))
    }

    @Test("Real-LLM-discovered validator rejection: a branch step's own action must be verifyOnly, even when its condition checks app-level state, not just element state")
    func testBranchStepMustBeVerifyOnlyEvenForAppStateConditions() {
        // The exact shape SEM-P4-B produced live (twice, consistently) once it correctly started using
        // applicationStateIs: it still attached the branch to a step whose own "action" was "appState",
        // as if the app-state check needed to happen via the step's action rather than purely inside the
        // condition. The validator's rule (a branch step is always a pure decision node) predates this
        // phase and was correctly enforced — the fix is prompt guidance, not a validator change.
        let badStep = IRStep(id: "s1", sourceStepNumber: 1, intent: "check foreground", action: .appState,
                              branch: IRBranch(condition: .applicationStateIs(.runningForeground),
                                                thenSteps: [IRStep(id: "s1-then", sourceStepNumber: 1, intent: "verify home", action: .verifyOnly)],
                                                elseSteps: [IRStep(id: "s1-else", sourceStepNumber: 1, intent: "relaunch", action: .launchAppPrecondition)]))
        let result = TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [badStep]))
        #expect(!result.isAccepted, "a branch step's action must always be verifyOnly, regardless of what the condition checks")

        let goodStep = IRStep(id: "s1", sourceStepNumber: 1, intent: "check foreground", action: .verifyOnly,
                               branch: badStep.branch)
        let goodResult = TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [goodStep]))
        #expect(goodResult.isAccepted)

        let prompt = TestIRGenerator.prompt(testKey: "T", title: "t", stepsText: "x")
        #expect(prompt.contains("is a pure decision node, never a device action"))
        #expect(prompt.contains("applicationStateIs/appState-flavored conditions"))
    }
}
