import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Generation-hardening contract: AIO/NL -> IR generation robustness, sections 3 and 6. A dataset of natural-language test
/// descriptions unrelated to DEMO-TC-872, each generated through the *real* `TestIRGenerator.generate()`
/// entry point (a deterministic fake `LLMClientProtocol` stands in for the model — no network, per section
/// 9), never hand-authored `TestIR` values passed directly to the executor. Combined with the 3 cases already
/// proven this way in `TestIRGeneralizationTests` (Portfolio-exists-or-More, Settings->Notifications,
/// login-form-exists-or-reopen), this dataset totals the 10 cases section 6 asks for.
///
/// Honesty note (section 3): the "multiple phrasings -> same IR" tests below prove the *pipeline* tolerates
/// arbitrary natural-language text (the phrasing only ever reaches the LLM prompt, never decode/validation),
/// using the same canned response for every phrasing to stand in for "a correctly functioning LLM would map
/// all of these the same way." They do not themselves prove a real model's semantic quality — that would
/// require the live LLM path this phase deliberately does not exercise (see `TestIRGenerationHardeningTests
/// .testRealLLMClientIsADropIn`).
@Suite("IR.9 Generalization Dataset")
struct TestIRGeneralizationDatasetTests {

    static func target(_ role: String, id: String? = nil, label: String? = nil) -> IRTarget { IRTarget(role: role, identifier: id, label: label) }
    static func el(_ role: String, id: String? = nil, label: String? = nil) -> ScenarioExpectedElement { ScenarioExpectedElement(role: role, identifier: id, label: label) }
    static let frame = ElementFrame(x: 0, y: 0, width: 100, height: 40)

    static func generate(_ ir: TestIR, stepsText: String) async throws -> TestIR {
        let mock = SequentialMockLLMClient(queuedResponses: [.success(String(data: ir.encoded(), encoding: .utf8)!)])
        return try await TestIRGenerator(llmClient: mock).generate(testKey: ir.testKey, title: ir.title, stepsText: stepsText)
    }

    // MARK: - Section 3: multiple phrasings of the same intent tolerate arbitrary NL text through the pipeline

    @Test("Four differently-worded phrasings of 'tap Collection' all decode/validate to the same IR through the same generator")
    func testMultiplePhrasingsProduceEquivalentIR() async throws {
        let sourceIR = TestIR(testKey: "PHRASING-1", title: "tap collection", steps: [
            IRStep(id: "p1", sourceStepNumber: 1, intent: "tap Collection", action: .selectTab, target: Self.target("button", label: "Collection"),
                   verification: IRVerification(description: "Collection visible", requiredElements: [Self.el("staticText", id: "chips_row")]))
        ])
        let phrasings = [
            "Tap Collection",
            "Open the Collection tab",
            "Navigate to Collection from the bottom bar",
            "Select Collection in bottom navigation"
        ]
        var results: [TestIR] = []
        for phrasing in phrasings { results.append(try await Self.generate(sourceIR, stepsText: phrasing)) }
        for ir in results {
            #expect(ir.steps.count == 1)
            #expect(ir.steps[0].action == .selectTab)
            #expect(ir.steps[0].target?.label == "Collection")
            #expect(TestIRValidator.validate(ir).isAccepted)
        }
    }

    // MARK: - Case 1: Login -> Portfolio (linear, credentialed)

    @Test("Case 1: Login -> Portfolio")
    func testCase1LoginToPortfolio() async throws {
        let sourceIR = TestIR(testKey: "GEN-1", title: "Login to Portfolio", steps: [
            IRStep(id: "1a", sourceStepNumber: 1, intent: "enter username", action: .typeText, target: Self.target("textField", id: "username_field"), arguments: ["text": .string("r.ruwan")]),
            IRStep(id: "1b", sourceStepNumber: 1, intent: "enter password", action: .typeText, target: Self.target("secureTextField", id: "password_field"), credentialRef: "TEST_USER_PASSWORD"),
            IRStep(id: "1c", sourceStepNumber: 1, intent: "tap Login", action: .tap, target: Self.target("button", label: "Log In"),
                   verification: IRVerification(description: "home loads", requiredElements: [Self.el("button", label: "Portfolio")])),
            IRStep(id: "1d", sourceStepNumber: 1, intent: "open Portfolio", action: .tap, target: Self.target("button", label: "Portfolio"),
                   verification: IRVerification(description: "Portfolio opens", requiredElements: [Self.el("staticText", id: "portfolio_screen")]))
        ])
        let ir = try await Self.generate(sourceIR, stepsText: "Log in, then open Portfolio.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)
        #expect(ir.steps.contains { $0.credentialRef == "TEST_USER_PASSWORD" })
        #expect(!SecretRedactor.containsSecret(String(data: ir.encoded(), encoding: .utf8) ?? ""))
    }

    // MARK: - Case 4: Search -> select result (linear)

    @Test("Case 4: Search -> select a result")
    func testCase4SearchSelectResult() async throws {
        let sourceIR = TestIR(testKey: "GEN-4", title: "Search and select", steps: [
            IRStep(id: "4a", sourceStepNumber: 1, intent: "tap search field", action: .tap, target: Self.target("searchField", label: "Search"),
                   verification: IRVerification(description: "search field focused", requiredElements: [Self.el("searchField", label: "Search")])),
            IRStep(id: "4b", sourceStepNumber: 1, intent: "type query", action: .typeText, target: Self.target("searchField", label: "Search"), arguments: ["text": .string("MSFT")],
                   verification: IRVerification(description: "results shown", requiredElements: [Self.el("staticText", label: "MSFT")])),
            IRStep(id: "4c", sourceStepNumber: 1, intent: "select the top result", action: .tap, target: Self.target("button", id: "result_0"),
                   verification: IRVerification(description: "result selected", signals: [.selectedBecame(SignalLocator(role: "button", identifier: "result_0"))]))
        ])
        let ir = try await Self.generate(sourceIR, stepsText: "Search for MSFT and select the top result.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)
        #expect(ir.steps.map(\.action) == [.tap, .typeText, .tap])

        let driver = SimulatedDriver(currentSnapshot: Observation(snapshotID: "s0", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e1", role: "searchField", label: "Search", frame: Self.frame)]))
        // post-4a / pre-4b: field still focused, nothing typed yet.
        await driver.queueNextSnapshot(Observation(snapshotID: "s1", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e1", role: "searchField", label: "Search", frame: Self.frame)]))
        // post-4b / pre-4c: MSFT results appear, not yet selected.
        await driver.queueNextSnapshot(Observation(snapshotID: "s2", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e2", role: "staticText", label: "MSFT", frame: Self.frame), UIElementSnapshot(id: "e3", role: "button", identifier: "result_0", isSelected: false, frame: Self.frame)]))
        // post-4c: the result becomes selected.
        await driver.queueNextSnapshot(Observation(snapshotID: "s3", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e3", role: "button", identifier: "result_0", isSelected: true, frame: Self.frame)]))
        let (records, _) = try await IRTestRunner.run(ir.steps, verdicts: result.stepVerdicts, testKey: "GEN-4", title: ir.title,
                                                       credentials: [:], driver: driver, toolRegistry: ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver))
        #expect(records.count == 3)
        for record in records { guard case .step(_, let verified, let reason) = record else { Issue.record("\(records)"); continue }; #expect(verified, Comment(rawValue: reason)) }
    }

    // MARK: - Case 5: existing item -> select; otherwise create (branch, generic — not literally Collection/Test1)

    @Test("Case 5: an existing 'Favorites' collection -> select it; otherwise create it")
    func testCase5ExistingOrCreate() async throws {
        let sourceIR = TestIR(testKey: "GEN-5", title: "Favorites select-or-create", steps: [
            IRStep(id: "5-branch", sourceStepNumber: 1, intent: "select Favorites if it exists, else create it", action: .verifyOnly,
                   branch: IRBranch(
                       condition: .elementExists(Self.target("button", label: "Favorites")),
                       thenSteps: [IRStep(id: "5-then", sourceStepNumber: 1, intent: "select Favorites", action: .tap, target: Self.target("button", label: "Favorites"),
                                          verification: IRVerification(description: "Favorites active", signals: [.selectedBecame(SignalLocator(role: "button", label: "Favorites"))]))],
                       elseSteps: [
                           IRStep(id: "5-else-tap", sourceStepNumber: 1, intent: "tap create", action: .tap, target: Self.target("button", label: "Create Collection"),
                                  verification: IRVerification(description: "name field opens", requiredElements: [Self.el("textField", id: "collection_name")])),
                           IRStep(id: "5-else-name", sourceStepNumber: 1, intent: "name it Favorites", action: .typeText, target: Self.target("textField", id: "collection_name"), arguments: ["text": .string("Favorites")],
                                  verification: IRVerification(description: "Favorites chip visible", requiredElements: [Self.el("button", label: "Favorites")]))
                       ]))
        ])
        let ir = try await Self.generate(sourceIR, stepsText: "If a Favorites collection already exists, select it; otherwise create one named Favorites.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)
        let branch = try #require(ir.steps.first?.branch)
        guard case .elementExists = branch.condition else { Issue.record("expected elementExists"); return }

        // Case: absent -> ELSE (create) only.
        let driver = SimulatedDriver(currentSnapshot: Observation(snapshotID: "s0", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e1", role: "button", label: "Create Collection", frame: Self.frame)]))
        await driver.queueNextSnapshot(Observation(snapshotID: "s1", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e2", role: "textField", identifier: "collection_name", frame: Self.frame)]))
        await driver.queueNextSnapshot(Observation(snapshotID: "s2", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e3", role: "button", label: "Favorites", frame: Self.frame)]))
        let (records, _) = try await IRTestRunner.run(ir.steps, verdicts: result.stepVerdicts, testKey: "GEN-5", title: ir.title,
                                                       credentials: [:], driver: driver, toolRegistry: ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver))
        guard case .branchSelected(_, .else, _) = records[0] else { Issue.record("\(records)"); return }
        #expect((await driver.invokedActionCount["tap"] ?? 0) == 1) // only "tap create", never "select Favorites"
    }

    // MARK: - Case 6: optional drawer -> dismiss if present, else no-op

    @Test("Case 6: optional drawer -> dismiss if present, else continue")
    func testCase6OptionalDrawer() async throws {
        let sourceIR = TestIR(testKey: "GEN-6", title: "Optional drawer", steps: [
            IRStep(id: "6-branch", sourceStepNumber: 1, intent: "dismiss the drawer if it appeared", action: .verifyOnly,
                   branch: IRBranch(condition: .elementExists(Self.target("button", id: "drawer_close")),
                                    thenSteps: [IRStep(id: "6-then", sourceStepNumber: 1, intent: "dismiss drawer", action: .tap, target: Self.target("button", id: "drawer_close"),
                                                       verification: IRVerification(description: "drawer gone", forbiddenElements: [Self.el("button", id: "drawer_close")]))],
                                    elseSteps: []))
        ])
        let ir = try await Self.generate(sourceIR, stepsText: "If an optional drawer appears, dismiss it; otherwise continue.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)
        #expect(ir.steps.first?.branch?.elseSteps.isEmpty == true, "the 'continue' half of an optional-condition is legitimately an empty arm")

        // Case: drawer absent -> ELSE (empty) -> nothing dispatches at all.
        let driver = SimulatedDriver(currentSnapshot: Observation(snapshotID: "s0", bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: []))
        let (records, _) = try await IRTestRunner.run(ir.steps, verdicts: result.stepVerdicts, testKey: "GEN-6", title: ir.title,
                                                       credentials: [:], driver: driver, toolRegistry: ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver))
        #expect(records.count == 1) // just the branch selection
        #expect((await driver.invokedActionCount["tap"] ?? 0) == 0)
    }

    // MARK: - Case 8: selected tab -> verify content (linear, ends in verifyOnly)

    @Test("Case 8: select a tab and verify its content is displayed")
    func testCase8SelectedTabVerifyContent() async throws {
        let sourceIR = TestIR(testKey: "GEN-8", title: "Tab content", steps: [
            IRStep(id: "8a", sourceStepNumber: 1, intent: "select the Orders tab", action: .tap, target: Self.target("button", label: "Orders"),
                   verification: IRVerification(description: "Orders active", signals: [.selectedBecame(SignalLocator(role: "button", label: "Orders"))])),
            IRStep(id: "8b", sourceStepNumber: 1, intent: "verify Orders content displayed", action: .verifyOnly,
                   verification: IRVerification(description: "orders content visible", requiredElements: [Self.el("staticText", id: "orders_content")]))
        ])
        let ir = try await Self.generate(sourceIR, stepsText: "Select the Orders tab and verify its content is displayed.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)

        let driver = SimulatedDriver(currentSnapshot: Observation(snapshotID: "s0", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e1", role: "button", label: "Orders", isSelected: false, frame: Self.frame)]))
        await driver.queueNextSnapshot(Observation(snapshotID: "s1", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e1", role: "button", label: "Orders", isSelected: true, frame: Self.frame), UIElementSnapshot(id: "e2", role: "staticText", identifier: "orders_content", frame: Self.frame)]))
        let (records, _) = try await IRTestRunner.run(ir.steps, verdicts: result.stepVerdicts, testKey: "GEN-8", title: ir.title,
                                                       credentials: [:], driver: driver, toolRegistry: ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver))
        #expect(records.count == 2)
        for record in records { guard case .step(_, let verified, let reason) = record else { Issue.record("\(records)"); continue }; #expect(verified, Comment(rawValue: reason)) }
    }

    // MARK: - Case 9: table layout -> horizontal scroll -> verify column (linear)

    @Test("Case 9: switch to table layout, scroll horizontally, verify a trailing column header")
    func testCase9TableLayoutScrollVerifyColumn() async throws {
        let sourceIR = TestIR(testKey: "GEN-9", title: "Table layout scroll", steps: [
            IRStep(id: "9a", sourceStepNumber: 1, intent: "open layout control", action: .tap, target: Self.target("button", id: "layout_control"),
                   verification: IRVerification(description: "layout menu opens", requiredElements: [Self.el("button", label: "Table")])),
            IRStep(id: "9b", sourceStepNumber: 1, intent: "select table layout", action: .tap, target: Self.target("button", label: "Table"),
                   verification: IRVerification(description: "table active", requiredElements: [Self.el("staticText", label: "LAST")])),
            IRStep(id: "9c", sourceStepNumber: 1, intent: "scroll the grid horizontally", action: .scroll, target: Self.target("staticText", id: "grid"), arguments: ["direction": .string("right")],
                   verification: IRVerification(description: "trailing column reachable", requiredElements: [Self.el("staticText", label: "DESCRIPTION")]))
        ])
        let ir = try await Self.generate(sourceIR, stepsText: "Switch to table layout, scroll the grid horizontally, and verify the DESCRIPTION column becomes visible.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)
        #expect(ir.steps.map(\.action) == [.tap, .tap, .scroll])
    }

    // MARK: - Case 10: mixed conditional flow with a nested condition

    @Test("Case 10: nested condition (outer availability check, inner state check)")
    func testCase10NestedConditionalFlow() async throws {
        let inner = IRStep(id: "10-inner", sourceStepNumber: 1, intent: "if item is enabled, tap it; else long-press for options", action: .verifyOnly,
                            branch: IRBranch(condition: .elementEnabled(Self.target("button", id: "item_row")),
                                              thenSteps: [IRStep(id: "10-inner-then", sourceStepNumber: 1, intent: "tap item", action: .tap, target: Self.target("button", id: "item_row"),
                                                                  verification: IRVerification(description: "detail opens", requiredElements: [Self.el("staticText", id: "detail_screen")]))],
                                              elseSteps: [IRStep(id: "10-inner-else", sourceStepNumber: 1, intent: "long-press for options", action: .longPress, target: Self.target("button", id: "item_row"),
                                                                  verification: IRVerification(description: "options menu opens", requiredElements: [Self.el("staticText", id: "options_menu")]))]))
        let outer = IRStep(id: "10-outer", sourceStepNumber: 1, intent: "if the item exists at all, decide what to do with it; else report unsupported", action: .verifyOnly,
                            branch: IRBranch(condition: .elementExists(Self.target("button", id: "item_row")), thenSteps: [inner], elseSteps: []))
        let sourceIR = TestIR(testKey: "GEN-10", title: "Nested conditional", steps: [outer])
        let ir = try await Self.generate(sourceIR, stepsText: "If the item row exists: tap it if enabled, otherwise long-press it for options; if it doesn't exist at all, there is nothing to do.")
        let result = TestIRValidator.validate(ir)
        #expect(result.isAccepted)
        let outerBranch = try #require(ir.steps.first?.branch)
        let innerStep = try #require(outerBranch.thenSteps.first)
        #expect(innerStep.branch != nil, "the nested condition must survive generation as a real nested IRBranch, not flattened")

        // Outer TRUE (item exists) + inner FALSE (disabled) -> long-press only.
        let driver = SimulatedDriver(currentSnapshot: Observation(snapshotID: "s0", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e1", role: "button", identifier: "item_row", isEnabled: false, frame: Self.frame)]))
        await driver.queueNextSnapshot(Observation(snapshotID: "s1", bundleID: "com.apple.mobilesafari", appState: .runningForeground,
            elements: [UIElementSnapshot(id: "e2", role: "staticText", identifier: "options_menu", frame: Self.frame)]))
        let (records, _) = try await IRTestRunner.run(ir.steps, verdicts: result.stepVerdicts, testKey: "GEN-10", title: ir.title,
                                                       credentials: [:], driver: driver, toolRegistry: ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver))
        #expect(records.count == 3) // outer selection, inner selection, long-press step
        #expect((await driver.invokedActionCount["longPress"] ?? 0) == 1)
        #expect((await driver.invokedActionCount["tap"] ?? 0) == 0)
    }
}
