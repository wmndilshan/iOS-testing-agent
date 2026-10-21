import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Milestone 3 (Phase Next, section 15): every malicious/invalid shape must fail closed, either at strict
/// JSON decode (an unknown `IRAction`/missing required field never becomes a `TestIR` value at all) or at
/// `TestIRValidator` (a well-typed but unsafe document). Nothing here is ever partially admitted.
@Suite("IR.3 Test IR Security / Negative Tests")
struct TestIRSecurityTests {

    private func minimalIRJSON(stepJSON: String) -> String {
        """
        {"schemaVersion": 1, "testKey": "NEG-1", "title": "negative", "steps": [\(stepJSON)]}
        """
    }

    @Test("An unknown action string (e.g. run_shell / xcrun / executeSwift) fails to decode — never reaches TestIR")
    func testUnknownActionFailsClosed() {
        for bad in ["run_shell", "xcrun", "executeSwift", "arbitraryDriverMethod"] {
            let json = minimalIRJSON(stepJSON: #"{"id":"s1","sourceStepNumber":1,"intent":"x","action":"\#(bad)"}"#)
            #expect(TestIR.decode(json.data(using: .utf8)!) == nil, "action '\(bad)' must not decode")
        }
    }

    @Test("A coordinate-only target has no role and fails to decode; the closed coordinateTap action decodes but is validator-rejected as unsupported")
    func testCoordinateTargetFailsClosed() {
        // No "role" (required) — a raw x/y target cannot satisfy IRTarget's schema at all.
        let json = minimalIRJSON(stepJSON: #"{"id":"s1","sourceStepNumber":1,"intent":"x","action":"tap","target":{"x":100,"y":200}}"#)
        #expect(TestIR.decode(json.data(using: .utf8)!) == nil)

        // The one explicitly-modeled "coordinate" action decodes (so it is reported, not silently dropped)
        // but is never admitted: IOSCapabilityRegistry marks coordinate_tap UNSUPPORTED by policy.
        let ir = TestIR(testKey: "NEG-1", title: "t", steps: [IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .coordinateTap)])
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)
        guard case .unsupported = result.stepVerdicts["s1"] else { Issue.record("coordinateTap must be unsupported"); return }
    }

    @Test("A step whose capability status is UNSUPPORTED/PLATFORM_LIMITATION is rejected by the validator, never treated as executable")
    func testUnsupportedCapabilityRejected() {
        for action in [IRAction.pullToRefresh, .systemDialogDismissal] {
            let ir = TestIR(testKey: "NEG-1", title: "t", steps: [IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: action)])
            let result = TestIRValidator.validate(ir)
            #expect(result.isAccepted)
            guard case .unsupported = result.stepVerdicts["s1"] else { Issue.record("\(action) must be unsupported"); continue }
        }
    }

    @Test("A literal password typed into a secureTextField is rejected outright, never accepted as ordinary test data")
    func testPlaintextPasswordRejected() {
        let step = IRStep(id: "s1", sourceStepNumber: 5, intent: "enter password", action: .typeText,
                           target: IRTarget(role: "secureTextField", identifier: "password_field"),
                           arguments: ["text": .string("hunter2")])
        let result = TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [step]))
        #expect(!result.isAccepted)
    }

    @Test("A credentialRef combined with a literal text argument is rejected (ambiguous secret source)")
    func testCredentialRefWithLiteralTextRejected() {
        let step = IRStep(id: "s1", sourceStepNumber: 5, intent: "enter password", action: .typeText,
                           target: IRTarget(role: "secureTextField", identifier: "password_field"),
                           arguments: ["text": .string("hunter2")], credentialRef: "TEST_USER_PASSWORD")
        let result = TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [step]))
        #expect(!result.isAccepted)
    }

    @Test("A malformed credentialRef (not a bare env-var-style name) is rejected")
    func testMalformedCredentialRefRejected() {
        for bad in ["hunter2", "TEST-PASSWORD!", "$(rm -rf /)", ""] {
            let step = IRStep(id: "s1", sourceStepNumber: 5, intent: "enter password", action: .typeText,
                               target: IRTarget(role: "secureTextField", identifier: "password_field"), credentialRef: bad)
            let result = TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [step]))
            #expect(!result.isAccepted, "credentialRef '\(bad)' should be rejected")
        }
    }

    @Test("An argument key that collides with a security-sensitive key is rejected")
    func testSecuritySensitiveArgumentKeyRejected() {
        for key in ["elementID", "snapshotID", "toolName", "scenarioID"] {
            let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .tap,
                               target: IRTarget(role: "button", label: "OK"), arguments: [key: .string("attacker-controlled")])
            let result = TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [step]))
            #expect(!result.isAccepted, "argument key '\(key)' should be rejected")
        }
    }

    @Test("A code/shell marker anywhere in a text field rejects the whole document")
    func testCodeMarkersRejected() {
        for marker in ["```", "xcrun simctl boot X", "import XCTest", "/bin/bash -c 'rm -rf /'"] {
            let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "Tap OK \(marker)", action: .tap, target: IRTarget(role: "button", label: "OK"))
            let result = TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [step]))
            #expect(!result.isAccepted, "marker '\(marker)' should be rejected")
        }
    }

    @Test("An API-key/JWT/bearer-token-shaped string anywhere is rejected (defense in depth via SecretRedactor)")
    func testSecretShapedStringRejected() {
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .tap,
                           target: IRTarget(role: "button", label: "OK"),
                           arguments: ["note": .string("AIzaSyD-1234567890abcdefghijklmnopqrstuv")])
        let result = TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [step]))
        #expect(!result.isAccepted)
    }

    @Test("A wait step with a timeout outside the tool's bound, or no identifier/label, is rejected")
    func testMalformedWaitRejected() {
        let tooLong = IRStep(id: "s1", sourceStepNumber: 1, intent: "wait", action: .waitForElement,
                              wait: IRWait(target: IRTarget(role: "button", identifier: "x"), timeoutSeconds: 3600))
        #expect(!TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [tooLong])).isAccepted)

        let noHandle = IRStep(id: "s1", sourceStepNumber: 1, intent: "wait", action: .waitForElement,
                               wait: IRWait(target: IRTarget(role: "button"), timeoutSeconds: 5))
        #expect(!TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [noHandle])).isAccepted)
    }

    @Test("An oversized document (too many steps) is rejected")
    func testOversizedDocumentRejected() {
        let steps = (0..<(TestIRValidator.maxSteps + 1)).map { i in
            IRStep(id: "s\(i)", sourceStepNumber: 1, intent: "x", action: .tap, target: IRTarget(role: "button", label: "OK"))
        }
        #expect(!TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: steps)).isAccepted)
    }

    @Test("A branch step that also carries a real action/target (not a pure decision node) is rejected")
    func testBranchStepWithRealActionRejected() {
        let branch = IRBranch(condition: .elementExists(IRTarget(role: "button", label: "OK")), thenSteps: [], elseSteps: [])
        let stepWithAction = IRStep(id: "s1", sourceStepNumber: 15, intent: "branch", action: .tap,
                                     target: IRTarget(role: "button", label: "OK"), branch: branch)
        #expect(!TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [stepWithAction])).isAccepted)

        let stepWithTargetOnly = IRStep(id: "s1", sourceStepNumber: 15, intent: "branch", action: .verifyOnly,
                                         target: IRTarget(role: "button", label: "OK"), branch: branch)
        #expect(!TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [stepWithTargetOnly])).isAccepted)
    }

    @Test("TestIRCompiler never compiles a step the validator rejected or marked unsupported without the caller checking first")
    func testCompilerSkipsUnsupportedAction() {
        let step = IRStep(id: "s1", sourceStepNumber: 2, intent: "x", action: .systemDialogDismissal)
        switch TestIRCompiler.compile(step) {
        case .compiled: Issue.record("systemDialogDismissal has no tool; it must never compile to a ScenarioStep")
        case .skipped: break
        }
    }

    @Test("A schemaVersion mismatch or unknown top-level field is refused by strict decode")
    func testSchemaVersionAndUnknownFieldRefused() {
        let wrongVersion = #"{"schemaVersion": 999, "testKey": "NEG-1", "title": "t", "steps": []}"#
        #expect(TestIR.decode(wrongVersion.data(using: .utf8)!) == nil)
        let extraField = #"{"schemaVersion": 1, "testKey": "NEG-1", "title": "t", "steps": [], "shellCommand": "rm -rf /"}"#
        #expect(TestIR.decode(extraField.data(using: .utf8)!) == nil)
    }

    // MARK: - Generic IR runtime control flow additions

    @Test("An unknown IRCondition case (or a hypothetical loop construct) fails to decode — never reaches TestIR")
    func testUnknownConditionAndLoopConstructFailClosed() throws {
        let encoder = JSONEncoder()
        // A well-formed branch step encodes with a "condition" object keyed by a real IRCondition case name
        // (SE-0295 synthesis). Swapping in an unmodeled key must fail, exactly like an unknown IRAction.
        let branch = IRBranch(condition: .elementExists(IRTarget(role: "button", label: "OK")), thenSteps: [], elseSteps: [])
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .verifyOnly, branch: branch)
        var stepData = try encoder.encode(step)
        var stepJSON = String(data: stepData, encoding: .utf8)!
        #expect(stepJSON.contains("elementExists"))
        // Swap the real case for an unmodeled "loop" key with while/for-shaped fields; must not decode.
        stepJSON = stepJSON.replacingOccurrences(of: #""elementExists""#, with: #""whileLoop""#)
        stepData = stepJSON.data(using: .utf8)!
        #expect((try? JSONDecoder().decode(IRStep.self, from: stepData)) == nil)

        let hypotheticalLoopJSON = #"{"id":"s1","sourceStepNumber":1,"intent":"x","action":"tap","target":{"role":"button","label":"OK"},"arguments":{},"loop":{"kind":"while","condition":{"elementExists":{"role":"button"}},"body":[]}}"#
        // "loop" is not a field IRStep declares; Codable ignores unknown keys, so this decodes as an
        // ordinary tap step (the loop payload is inert) rather than as anything resembling a loop construct.
        let decoded = try #require(try? JSONDecoder().decode(IRStep.self, from: hypotheticalLoopJSON.data(using: .utf8)!))
        #expect(decoded.action == .tap)
        #expect(decoded.branch == nil)
    }

    @Test("A malformed/oversized condition tree (deep nesting, oversized all/any list, code marker inside elementHasText) is rejected")
    func testMalformedConditionTreeRejected() {
        var deep = IRCondition.elementExists(IRTarget(role: "button", label: "X"))
        for _ in 0..<(TestIRValidator.maxConditionDepth + 2) { deep = .not(deep) }
        let deepStep = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .verifyOnly,
                               branch: IRBranch(condition: deep, thenSteps: [], elseSteps: []))
        #expect(!TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [deepStep])).isAccepted)

        let oversizedList = IRCondition.all((0..<(TestIRValidator.maxArguments + 5)).map { _ in .elementExists(IRTarget(role: "button", label: "X")) })
        let oversizedStep = IRStep(id: "s2", sourceStepNumber: 1, intent: "x", action: .verifyOnly,
                                    branch: IRBranch(condition: oversizedList, thenSteps: [], elseSteps: []))
        #expect(!TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [oversizedStep])).isAccepted)

        let codeInCondition = IRCondition.elementHasText(IRTarget(role: "textField", label: "X"), equals: "`; xcrun simctl erase all; `")
        let codeStep = IRStep(id: "s3", sourceStepNumber: 1, intent: "x", action: .verifyOnly,
                               branch: IRBranch(condition: codeInCondition, thenSteps: [], elseSteps: []))
        #expect(!TestIRValidator.validate(TestIR(testKey: "NEG-1", title: "t", steps: [codeStep])).isAccepted)
    }

    @Test("Fault E: a spoofed LLM-provided branch result field is decoded but has zero effect on which arm runs")
    func testSpoofedLLMBranchResultIgnored() async throws {
        // The condition is genuinely FALSE (no matching element in the observation used below), but the
        // document claims (in a field IRBranch does not declare, so it survives decoding as dead data)
        // that the LLM already "decided" true. IRConditionEvaluator must still evaluate the real condition.
        let json = """
        {"schemaVersion": 1, "testKey": "NEG-1", "title": "t", "steps": [
          {"id":"s1","sourceStepNumber":1,"intent":"x","action":"verifyOnly","arguments":{},
           "branch": {"condition": {"elementExists": {"_0": {"role":"button","label":"Nonexistent"}}},
                      "thenSteps": [{"id":"then1","sourceStepNumber":1,"intent":"then","action":"tap","target":{"role":"button","label":"ThenTarget"},"arguments":{}}],
                      "elseSteps": [{"id":"else1","sourceStepNumber":1,"intent":"else","action":"tap","target":{"role":"button","label":"ElseTarget"},"arguments":{}}],
                      "llmDecision": true, "result": true}}
        ]}
        """
        // Strict top-level decode already refuses unknown fields at the TestIR root, but a nested object
        // (inside IRBranch) is not root-level, so this still decodes — proving the spoofed field is inert
        // rather than merely unreachable.
        let ir = try #require(TestIR.decode(json.data(using: .utf8)!))
        let branch = try #require(ir.steps.first?.branch)

        let observation = Observation(snapshotID: "snap_1", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
                                       elements: [UIElementSnapshot(id: "e1", role: "button", label: "ElseTarget")])
        #expect(IRConditionEvaluator.evaluate(branch.condition, in: observation) == .notSatisfied)

        let placeholder = ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button"))
        let scenario = SafeScenario(id: "NEG-1", name: "t", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: placeholder)
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = await ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        let executor = await TestIRExecutor(controller: controller)
        let outcome = await executor.evaluateBranch(branch, freshObservation: observation)
        guard case .selected(let arm, _) = outcome else { Issue.record("expected a selection, got \(outcome)"); return }
        #expect(arm == .else, "the spoofed 'llmDecision/result: true' field must never override the real, deterministic evaluation")
    }

    // MARK: - Adversarial-IR contract, finding C: a verifyOnly step must never name a transition-only signal

    @Test("A verifyOnly step naming a transition signal (elementAppeared/selectedBecame/etc.) is rejected — it compares an observation against itself, so the signal can never hold; elementExists/foregroundApplication remain accepted")
    func testVerifyOnlyRejectsTransitionSignals() {
        func verifyOnlyStep(signal: ObservationSignal) -> TestIR {
            TestIR(testKey: "T", title: "t", steps: [
                IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .verifyOnly,
                       verification: IRVerification(description: "d", signals: [signal]))
            ])
        }
        let target = SignalLocator(role: "tab", label: "X")
        let transitionSignals: [ObservationSignal] = [
            .elementAppeared(target), .elementDisappeared(target), .labelChanged(identifier: "x"),
            .labelBecame(identifier: "x", to: "y"), .valueChanged(identifier: "x"), .selectedBecame(target),
            .navigationBarBecame(identifier: "x"), .keyboardBecame(visible: true), .accessibilitySnapshotChanged
        ]
        for signal in transitionSignals {
            let result = TestIRValidator.validate(verifyOnlyStep(signal: signal))
            #expect(!result.isAccepted, "verifyOnly + \(signal.name) must be rejected")
        }
        // The two state-only signals remain legitimately accepted on a verifyOnly step.
        #expect(TestIRValidator.validate(verifyOnlyStep(signal: .elementExists(target))).isAccepted)
        #expect(TestIRValidator.validate(verifyOnlyStep(signal: .foregroundApplication(bundleID: "com.apple.mobilesafari"))).isAccepted)
    }

    @Test("The generation prompt explicitly names this constraint and its wire-format example")
    func testPromptContainsVerifyOnlyTransitionSignalRule() {
        let prompt = TestIRGenerator.prompt(testKey: "T", title: "t", stepsText: "x")
        #expect(prompt.contains("its signals may ONLY be \"elementExists\" or"))
        #expect(prompt.contains("NEVER give a verifyOnly step a transition signal"))
    }

    // MARK: - Adversarial-IR contract, section 5A: a bare-role scope (within) is rejected, exactly like a bare-role target

    @Test("A target's scope (within) with neither identifier nor label is rejected — a bare-role scope can never resolve to a unique container")
    func testBareRoleScopeRejected() {
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .tap,
                           target: IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView")))
        let result = TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [step]))
        #expect(!result.isAccepted)
    }

    @Test("A properly specific scope (within) is accepted")
    func testSpecificScopeAccepted() {
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .tap,
                           target: IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView", label: "Collection Items")),
                           verification: IRVerification(description: "d"))
        let result = TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [step]))
        #expect(result.isAccepted, Comment(rawValue: result.rejectionReasons.joined(separator: "; ")))
    }

    @Test("A malformed scope inside a branch condition's target is also rejected (validateCondition's scanTarget path)")
    func testBareRoleScopeInConditionRejected() {
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .verifyOnly,
                           branch: IRBranch(condition: .elementExists(IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView"))), thenSteps: [], elseSteps: []))
        let result = TestIRValidator.validate(TestIR(testKey: "T", title: "t", steps: [step]))
        #expect(!result.isAccepted)
    }

    // MARK: - Adversarial-IR contract, real finding: a CONDITION-only case name used inside "signals" fails to decode

    @Test("A condition-only case name ('elementEnabled') used inside 'signals' is refused at decode — the real shape a live DeepSeek response produced (P43-TRANS1) — already correct, fail-closed decoder behavior, pinned here as a regression")
    func testConditionOnlyNameInSignalsFailsDecode() {
        let json = #"""
        {"schemaVersion":1,"testKey":"T","title":"t","steps":[{"id":"s1","sourceStepNumber":1,"intent":"x","action":"tap","target":{"role":"button","label":"Submit"},"arguments":{},"verification":{"description":"d","requiredElements":[],"forbiddenElements":[],"signals":[{"elementEnabled":{"_0":{"role":"button","label":"Login"}}}]}}]}
        """#
        #expect(TestIR.decode(json.data(using: .utf8)!) == nil, "'elementEnabled' is a condition-only case name; it must never decode as a signal")
    }

    @Test("The prompt explicitly separates the condition-only vocabulary from the signal vocabulary and names the requireEnabled state-check alternative")
    func testPromptDistinguishesConditionAndSignalVocabularies() {
        let prompt = TestIRGenerator.prompt(testKey: "T", title: "t", stepsText: "x")
        #expect(prompt.contains("are CONDITION kinds only"))
        #expect(prompt.contains("There is no \"became enabled\"/\"became disabled\" TRANSITION"))
    }
}
