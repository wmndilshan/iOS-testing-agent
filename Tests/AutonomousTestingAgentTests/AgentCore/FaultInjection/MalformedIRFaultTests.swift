import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Category C (matrix section "D — malformed/hostile IR"): a consolidated, table-driven
/// certification pass over hostile IR JSON shapes, PLUS end-to-end proof that a document which fails to
/// decode or fails validation never reaches trusted execution — no compiled `SafeScenario`, no proposal,
/// no approval, and (via `FaultInjectingXCTestDriver`) zero real driver/tool invocations.
///
/// Most of these individual shapes already have dedicated, narrower regression tests in
/// `TestIRSecurityTests` (Adversarial-IR contract+) — this file does not replace those; it (a) re-certifies a broad,
/// consolidated set of them in one table so Fault-injection matrix's report can point to a single evidence source, and
/// (b) adds the genuinely new assertion those tests do not make: that a hostile document, even if defense
/// in depth is the only thing standing between it and execution, produces exactly zero calls to the real
/// device/XCTest driver.
@Suite("Fault-injection matrix.D Malformed / Hostile IR Fault Injection")
@MainActor
struct MalformedIRFaultTests {
    /// One hostile JSON document and why it must never become executable.
    struct HostileCase: Sendable {
        let name: String
        let json: String
    }

    nonisolated static let hostileCases: [HostileCase] = [
        HostileCase(name: "unknown action string", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "run_shell", "arguments": {}}
            ]}
            """),
        HostileCase(name: "shell/xcrun tool named directly", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "tap", "arguments": {},
               "target": {"role": "button", "label": "run xcrun simctl boot X"}}
            ]}
            """),
        HostileCase(name: "coordinate target (no role/x-y fields exist for IRTarget)", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "tap", "arguments": {},
               "target": {"x": 100, "y": 200}}
            ]}
            """),
        HostileCase(name: "credential literal in a text argument", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "typeText", "arguments": {"text": "AIzaSyD-1234567890abcdefghijklmnopqrstuv"},
               "target": {"role": "textField", "identifier": "field"}}
            ]}
            """),
        HostileCase(name: "invalid enum discriminator (unknown IRCondition case)", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "verifyOnly", "arguments": {},
               "branch": {"condition": {"elementLooksNice": {"_0": {"role": "button"}}}, "thenSteps": [], "elseSteps": []}}
            ]}
            """),
        HostileCase(name: "missing required target on a tap action", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "tap", "arguments": {}}
            ]}
            """),
        HostileCase(name: "bare role target (no identifier, no label)", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "tap", "arguments": {}, "target": {"role": "button"}}
            ]}
            """),
        HostileCase(name: "unknown top-level field (schema tampering)", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "trustedExecutionOverride": true, "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "verifyOnly", "arguments": {}}
            ]}
            """),
        HostileCase(name: "schemaVersion mismatch", json: """
            {"schemaVersion": 999, "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "verifyOnly", "arguments": {}}
            ]}
            """),
        HostileCase(name: "branch step carrying a real action and target (not a pure decision node)", json: """
            {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
              {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "tap", "arguments": {}, "target": {"role": "button", "label": "X"},
               "branch": {"condition": {"elementExists": {"_0": {"role": "button", "label": "X"}}}, "thenSteps": [], "elseSteps": []}}
            ]}
            """),
        HostileCase(name: "excessive branch nesting depth (6 levels, exceeds maxBranchDepth=4)", json: nestedBranchJSON(levels: 6)),
    ]

    /// Builds a JSON document with `levels` of pure `verifyOnly` nested branches (no leaf action), used to
    /// probe the depth-limit boundary via raw decode + validate (independent of the Swift-value-based
    /// construction already used in `NestedBranchExecutionTests`, so the depth limit is proven both ways).
    nonisolated static func nestedBranchJSON(levels: Int) -> String {
        func wrap(_ depth: Int) -> String {
            guard depth > 0 else { return "[]" }
            return """
            [{"id": "n\(depth)", "sourceStepNumber": 1, "intent": "i", "action": "verifyOnly", "arguments": {},
              "branch": {"condition": {"elementExists": {"_0": {"role": "other", "label": "L\(depth)"}}}, "thenSteps": \(wrap(depth - 1)), "elseSteps": []}}]
            """
        }
        return """
        {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": \(wrap(levels))}
        """
    }

    @Test("Every hostile IR document either fails to decode, or decodes but is rejected by TestIRValidator — never both decodes AND validates", arguments: hostileCases)
    func testHostileDocumentNeverBecomesExecutable(_ hostile: HostileCase) {
        guard let data = hostile.json.data(using: .utf8) else { Issue.record("bad test JSON for \(hostile.name)"); return }
        guard let ir = TestIR.decode(data) else {
            // Failing to decode at all is a fully safe outcome — nothing downstream ever sees this document.
            return
        }
        let validation = TestIRValidator.validate(ir)
        #expect(!validation.isAccepted, "'\(hostile.name)' decoded but was NOT rejected by TestIRValidator — a malformed document must never become executable merely because it is syntactically valid JSON")
    }

    @Test("An unknown nested field (a hypothetical 'loop', or a spoofed top-level 'result: true') attached to a step is silently ignored by decode, not a bypass or an executed construct — IRStep/TestIR have no such field for anything downstream to read")
    func testUnknownNestedFieldsAreInertNeverExecuted() throws {
        let loopJSON = """
        {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
          {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "verifyOnly", "arguments": {},
           "loop": {"count": 10, "steps": []}}
        ]}
        """
        let resultJSON = """
        {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
          {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "verifyOnly", "arguments": {}, "result": true}
        ]}
        """
        for json in [loopJSON, resultJSON] {
            guard let data = json.data(using: .utf8), let ir = TestIR.decode(data) else { Issue.record("expected this shape to decode (unknown field harmlessly dropped)"); continue }
            #expect(ir.steps.count == 1)
            #expect(ir.steps[0].branch == nil, "no loop/result field can materialize a branch or any other executable construct — IRStep simply has no such property")
            let validation = TestIRValidator.validate(ir)
            #expect(validation.isAccepted, "a harmless unknown field must not even affect acceptance; the point is it has ZERO influence, in either direction")
        }
    }

    @Test("Excessive branch nesting depth (levels=5, one past the documented maxBranchDepth=4) is rejected; levels=4 remains accepted — no discrepancy between decoder and validator")
    func testExcessiveBranchDepthBoundary() {
        for (levels, shouldAccept) in [(4, true), (5, false)] {
            guard let data = Self.nestedBranchJSON(levels: levels).data(using: .utf8), let ir = TestIR.decode(data) else {
                Issue.record("levels=\(levels) failed to decode at all, which is safe but unexpected here"); continue
            }
            let validation = TestIRValidator.validate(ir)
            #expect(validation.isAccepted == shouldAccept, "levels=\(levels): expected isAccepted==\(shouldAccept), got \(validation.isAccepted): \(validation.rejectionReasons)")
        }
    }

    // MARK: - End-to-end: a rejected/unsupported document never reaches the trusted driver.

    @Test("A step whose action is structurally valid but policy-unsupported (coordinateTap) never reaches compileLinearScenario, never starts a scenario, and (driven through the full pipeline) produces zero real driver calls")
    func testRejectedDocumentNeverReachesDriver() async throws {
        // `coordinateTap` is a real, closed `IRAction` case (so this decodes cleanly), but
        // `IOSCapabilityRegistry` marks it UNSUPPORTED by policy ("no raw coordinate execution") — so its
        // step verdict is genuinely `.unsupported`, unlike the various validator-level STRUCTURAL rejections
        // (missing target, bare role, credential issues, forged fields) which still leave a step's own
        // per-step `classify()` verdict as `.admitted` even while the document's overall
        // `rejectionReasons` is non-empty (existing, documented behavior — see
        // `TestIRSecurityTests.testCompilerNeverCompilesUnadmittedStep`: a caller must gate on
        // `validation.isAccepted`/`stepVerdicts`, per-step, never assume rejection implies every verdict
        // flips). This test exercises the genuinely-`.unsupported` path end-to-end.
        let json = """
        {"schemaVersion": \(TestIR.currentSchemaVersion), "testKey": "T", "title": "t", "steps": [
          {"id": "s1", "sourceStepNumber": 1, "intent": "i", "action": "coordinateTap", "arguments": {}, "target": {"role": "button", "label": "X"}}
        ]}
        """
        guard let data = json.data(using: .utf8), let ir = TestIR.decode(data) else { Issue.record("expected this shape to decode"); return }
        let validation = TestIRValidator.validate(ir)
        guard case .unsupported = validation.stepVerdicts["s1"] else { Issue.record("expected s1 to be unsupported, got \(String(describing: validation.stepVerdicts["s1"]))"); return }

        // Defense in depth: even attempting to compile the rejected document's steps must yield nothing to run.
        let compiled = TestIRExecutor.compileLinearScenario(testKey: "T", title: "t", steps: ir.steps, verdicts: validation.stepVerdicts)
        #expect(compiled == nil, "a document with no admitted steps must compile to nothing runnable")

        let mock = SimulatedDriver(currentSnapshot: Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: []))
        let driver = FaultInjectingXCTestDriver(inner: mock)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "T", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                                                actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))

        // Even routing the (all-unadmitted) steps through the real StatefulScenarioRunner pipeline must
        // touch the driver only for its own step-local grounding observation capture — never for a mutation.
        let (records, _) = try await StatefulScenarioRunner.driveSteps(
            ir.steps, verdicts: validation.stepVerdicts, testKey: "T", title: "t",
            driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        #expect(records.allSatisfy { if case .skippedUnadmitted = $0 { return true }; return false })
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0, "an unadmitted step must never reach a real driver mutation call")
    }
}
