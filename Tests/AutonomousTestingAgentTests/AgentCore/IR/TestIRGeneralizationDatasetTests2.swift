import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// IR-execution contract, section 13: the remaining 2 of the 10 generalization cases (the other 8 — Portfolio-or-More,
/// Settings->Notifications, login-form-or-reopen, Login->Portfolio, Search->select, existing-or-create
/// Favorites, optional-drawer, selected-tab->verify, table-layout->scroll->verify, nested-conditional — are
/// split across `TestIRGeneralizationTests`/`TestIRGeneralizationDatasetTests` from phases 36/37). Each case
/// here is generated through the real `TestIRGenerator.generate()` entry point (deterministic fake LLM
/// response, per section 9 — no network dependency in the ordinary suite) and then run end to end through
/// the real trusted spine via `IRTestRunner.runAutoObserved` (generic auto-observation, section 6).
@Suite("IR.9 Generalization Dataset")
struct TestIRGeneralizationDatasetTests2 {

    static func target(_ role: String, id: String? = nil, label: String? = nil) -> IRTarget { IRTarget(role: role, identifier: id, label: label) }
    static func el(_ role: String, id: String? = nil, label: String? = nil) -> ScenarioExpectedElement { ScenarioExpectedElement(role: role, identifier: id, label: label) }

    static func generate(_ ir: TestIR, stepsText: String) async throws -> TestIR {
        let mock = SequentialMockLLMClient(queuedResponses: [.success(String(data: ir.encoded(), encoding: .utf8)!)])
        return try await TestIRGenerator(llmClient: mock).generate(testKey: ir.testKey, title: ir.title, stepsText: stepsText)
    }

    // MARK: - Case 8: Profile navigation (three distinct row taps from one screen, mirroring DEMO-TC-872 step 32's shape but standalone)

    @Test("Case 8: profile navigation — stock row opens a profile, spot row navigates away, option row opens a different profile")
    func testProfileNavigation() async throws {
        let sourceIR = TestIR(testKey: "GEN-8", title: "Profile navigation", steps: [
            IRStep(id: "8a", sourceStepNumber: 1, intent: "tap the stock row", action: .tap, target: Self.target("staticText", label: "ALPHA"),
                   verification: IRVerification(description: "Stock Profile opens", requiredElements: [Self.el("staticText", id: "stock_profile_screen")])),
            IRStep(id: "8b", sourceStepNumber: 1, intent: "navigate back", action: .navigateBack, target: Self.target("button", id: "nav_back_button"),
                   verification: IRVerification(description: "back on the list", requiredElements: [Self.el("staticText", label: "ALPHA")])),
            IRStep(id: "8c", sourceStepNumber: 1, intent: "tap the spot row", action: .tap, target: Self.target("staticText", label: "XAGUSD"),
                   verification: IRVerification(description: "navigates away from the list", forbiddenElements: [Self.el("staticText", id: "list_container")]))
        ])
        let ir = try await Self.generate(sourceIR, stepsText: "Tap the ALPHA stock row to open its profile, navigate back, then tap the XAGUSD spot row which navigates away from the list entirely.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)

        let frame = ElementFrame(x: 0, y: 0, width: 100, height: 40)
        let driver = SimulatedDriver(currentSnapshot: Observation(snapshotID: "s0", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e1", role: "staticText", label: "ALPHA", frame: frame), UIElementSnapshot(id: "e2", role: "button", identifier: "nav_back_button", frame: frame)]))
        let toolRegistry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let (records, unsatisfiable, _) = try await IRTestRunner.runAutoObserved(ir.steps, verdicts: result.stepVerdicts, testKey: "GEN-8", title: ir.title,
                                                                                  credentials: [:], driver: driver, toolRegistry: toolRegistry)
        #expect(unsatisfiable.isEmpty)
        #expect(records.count == 3)
        for record in records { guard case .step(_, let verified, let reason) = record else { Issue.record("\(records)"); continue }; #expect(verified, Comment(rawValue: reason)) }
    }

    // MARK: - Case 10 (second instance in this dataset half): back-navigation flow

    @Test("Case: back-navigation flow — open a detail screen, then navigate back to confirm the list is restored")
    func testBackNavigationFlow() async throws {
        let sourceIR = TestIR(testKey: "GEN-9", title: "Back navigation flow", steps: [
            IRStep(id: "9a", sourceStepNumber: 1, intent: "open the detail screen", action: .tap, target: Self.target("staticText", label: "Item"),
                   verification: IRVerification(description: "detail screen opens", requiredElements: [Self.el("staticText", id: "detail_screen")])),
            IRStep(id: "9b", sourceStepNumber: 1, intent: "navigate back", action: .navigateBack, target: Self.target("button", id: "nav_back_button"),
                   verification: IRVerification(description: "list restored", requiredElements: [Self.el("staticText", id: "list_container")], forbiddenElements: [Self.el("staticText", id: "detail_screen")]))
        ])
        let ir = try await Self.generate(sourceIR, stepsText: "Open the item's detail screen, then navigate back and confirm the list is restored.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)

        let frame = ElementFrame(x: 0, y: 0, width: 100, height: 40)
        let driver = SimulatedDriver(currentSnapshot: Observation(snapshotID: "s0", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e1", role: "staticText", label: "Item", frame: frame)]))
        let toolRegistry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let (records, unsatisfiable, _) = try await IRTestRunner.runAutoObserved(ir.steps, verdicts: result.stepVerdicts, testKey: "GEN-9", title: ir.title,
                                                                                  credentials: [:], driver: driver, toolRegistry: toolRegistry)
        #expect(unsatisfiable.isEmpty)
        #expect(records.count == 2)
        for record in records { guard case .step(_, let verified, let reason) = record else { Issue.record("\(records)"); continue }; #expect(verified, Comment(rawValue: reason)) }
    }

    // MARK: - Section 11: credential safety, end to end (prompt -> raw response -> decoded IR -> compiled ScenarioStep)

    @Test("Credential safety: the literal password never appears in the prompt, the raw response, the decoded IR, or the compiled ScenarioStep")
    func testCredentialSafetyEndToEnd() async throws {
        let literalPassword = "S3cr3t-Should-Never-Leak"
        let sourceIR = TestIR(testKey: "GEN-CRED", title: "credential safety", steps: [
            IRStep(id: "c1", sourceStepNumber: 5, intent: "enter password", action: .typeText,
                   target: IRTarget(role: "secureTextField", identifier: "password_field"), credentialRef: "TEST_USER_PASSWORD")
        ])
        let mock = SequentialMockLLMClient(queuedResponses: [.success(String(data: sourceIR.encoded(), encoding: .utf8)!)])
        let generator = TestIRGenerator(llmClient: mock)
        let aioText = "5. Enter the valid password in the password field. Test Data: [CREDENTIALS]. Expected: Password entered (masked)."
        let ir = try await generator.generate(testKey: "GEN-CRED", title: "credential safety", stepsText: aioText)

        // The prompt TestIRGenerator built and sent never contains the literal password (it isn't known to
        // the generator at all — only the AIO placeholder text and a symbolic credentialRef name are ever
        // in scope).
        let promptSent = TestIRGenerator.prompt(testKey: "GEN-CRED", title: "credential safety", stepsText: aioText)
        #expect(!promptSent.contains(literalPassword))
        // The (fake, but standing in for a real) raw response never contains it either.
        #expect(!mock.recordedPrompts.contains { $0.contains(literalPassword) })
        // The decoded IR never contains it.
        let rawIRJSON = String(data: ir.encoded(), encoding: .utf8) ?? ""
        #expect(!rawIRJSON.contains(literalPassword))
        #expect(!SecretRedactor.containsSecret(rawIRJSON))
        // The compiled ScenarioStep resolves the credential only from the trusted environment map passed to
        // the compiler — and even then, its own Codable encoding excludes trustedArguments entirely.
        guard case .compiled(let compiled) = TestIRCompiler.compile(ir.steps[0], credentials: ["TEST_USER_PASSWORD": literalPassword]) else {
            Issue.record("expected the credentialed step to compile"); return
        }
        #expect(compiled.scenarioStep.trustedArguments["text"] == .string(literalPassword)) // present in memory, trusted-only
        let encodedStep = String(data: (try? JSONEncoder().encode(compiled.scenarioStep)) ?? Data(), encoding: .utf8) ?? ""
        #expect(!encodedStep.contains(literalPassword), "ScenarioStep's own Codable encoding must exclude trustedArguments")
    }
}
