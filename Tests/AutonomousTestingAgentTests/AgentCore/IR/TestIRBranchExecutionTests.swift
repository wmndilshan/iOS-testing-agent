import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Phase: generic IR runtime control flow. Proves `IRBranch` actually executes conditionally — not just
/// validates/compiles — through the real trusted spine, via the generic `IRTestRunner`/`TestIRExecutor`
/// mechanism (no DEMO-TC-872-specific or example-specific code in the engine itself).
@Suite("IR.5 Branch Execution")
struct TestIRBranchExecutionTests {

    static let frame = ElementFrame(x: 0, y: 0, width: 100, height: 40)

    static func el(_ role: String, id: String? = nil, label: String? = nil, isSelected: Bool? = nil) -> UIElementSnapshot {
        UIElementSnapshot(id: "e_\(UUID().uuidString.prefix(6))", role: role, label: label, identifier: id, isSelected: isSelected, frame: frame)
    }

    static func obs(_ elements: [UIElementSnapshot], id: String = "snap_\(UUID().uuidString.prefix(6))") -> Observation {
        Observation(snapshotID: id, bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: elements)
    }

    static func toolRegistry(_ driver: SimulatedDriver) -> ToolRegistry {
        ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
    }

    /// Real verdicts for an ad-hoc test step (never a hand-faked `[:]`): `TestIRExecutor.compileLinearScenario`
    /// only compiles a step `TestIRValidator` actually marked `.admitted`.
    static func verdicts(for steps: [IRStep]) -> [String: IRStepVerdict] {
        TestIRValidator.validate(TestIR(testKey: "GENERIC", title: "generic", steps: steps)).stepVerdicts
    }

    // MARK: - DEMO-TC-872 Step 15, both cases (the proving case)

    // MARK: - Generic example 1: empty-arm, unrelated to Collection

    static func loginBranchStep(thenVerifyTarget: String) -> IRStep {
        IRStep(id: "g1-branch", sourceStepNumber: 1, intent: "tap Login if it exists, else continue", action: .verifyOnly,
               branch: IRBranch(
                   condition: .elementExists(IRTarget(role: "button", identifier: "login_button")),
                   thenSteps: [IRStep(id: "g1-then-tap", sourceStepNumber: 1, intent: "tap Login", action: .tap,
                                       target: IRTarget(role: "button", identifier: "login_button"),
                                       verification: IRVerification(description: "home appears", requiredElements: [ScenarioExpectedElement(role: "button", label: thenVerifyTarget)]))],
                   elseSteps: []))
    }

    @Test("Generic example 1 (Login button exists / continue): TRUE taps Login; FALSE is a true no-op")
    @MainActor
    func testGenericExample1LoginExistsOrContinue() async throws {
        // Case TRUE
        do {
            let driver = SimulatedDriver(currentSnapshot: Self.obs([Self.el("button", id: "login_button")]))
            await driver.queueNextSnapshot(Self.obs([Self.el("button", label: "Home")]))
            let (records, _) = try await IRTestRunner.run([Self.loginBranchStep(thenVerifyTarget: "Home")], verdicts: Self.verdicts(for: [Self.loginBranchStep(thenVerifyTarget: "Home")]),
                                                            testKey: "GENERIC-1", title: "g1", credentials: [:], driver: driver, toolRegistry: Self.toolRegistry(driver))
            #expect(records.count == 2)
            guard case .branchSelected(_, let arm, _) = records[0] else { Issue.record("\(records)"); return }
            #expect(arm == .then)
            #expect((await driver.invokedActionCount["tap"] ?? 0) == 1)
        }
        // Case FALSE: no Login button -> empty else arm -> literally nothing dispatches
        do {
            let driver = SimulatedDriver(currentSnapshot: Self.obs([]))
            let (records, _) = try await IRTestRunner.run([Self.loginBranchStep(thenVerifyTarget: "Home")], verdicts: Self.verdicts(for: [Self.loginBranchStep(thenVerifyTarget: "Home")]),
                                                            testKey: "GENERIC-1", title: "g1", credentials: [:], driver: driver, toolRegistry: Self.toolRegistry(driver))
            #expect(records.count == 1)
            guard case .branchSelected(_, let arm, _) = records[0] else { Issue.record("\(records)"); return }
            #expect(arm == .else)
            #expect((await driver.invokedActionCount["tap"] ?? 0) == 0)
        }
    }

    // MARK: - Generic example 2: two distinct non-empty arms, unrelated to Collection

    static func portfolioBranchStep() -> IRStep {
        IRStep(id: "g2-branch", sourceStepNumber: 2, intent: "select Portfolio if present, else fall back to More", action: .verifyOnly,
               branch: IRBranch(
                   condition: .elementExists(IRTarget(role: "button", label: "Portfolio")),
                   thenSteps: [IRStep(id: "g2-then-portfolio", sourceStepNumber: 2, intent: "select Portfolio", action: .tap,
                                       target: IRTarget(role: "button", label: "Portfolio"),
                                       verification: IRVerification(description: "portfolio screen", requiredElements: [ScenarioExpectedElement(role: "staticText", identifier: "portfolio_screen")]))],
                   elseSteps: [IRStep(id: "g2-else-more", sourceStepNumber: 2, intent: "fall back to More", action: .tap,
                                       target: IRTarget(role: "button", label: "More"),
                                       verification: IRVerification(description: "more screen", requiredElements: [ScenarioExpectedElement(role: "staticText", identifier: "more_screen")]))]))
    }

    @Test("Generic example 2 (Portfolio tab exists / fall back to More): each case runs only its own arm's tap")
    @MainActor
    func testGenericExample2PortfolioOrMore() async throws {
        // Case TRUE: Portfolio present
        do {
            let driver = SimulatedDriver(currentSnapshot: Self.obs([Self.el("button", label: "Portfolio"), Self.el("button", label: "More")]))
            await driver.queueNextSnapshot(Self.obs([Self.el("staticText", id: "portfolio_screen")]))
            let (records, _) = try await IRTestRunner.run([Self.portfolioBranchStep()], verdicts: Self.verdicts(for: [Self.portfolioBranchStep()]), testKey: "GENERIC-2", title: "g2",
                                                            credentials: [:], driver: driver, toolRegistry: Self.toolRegistry(driver))
            guard case .branchSelected(_, .then, _) = records[0] else { Issue.record("\(records)"); return }
            guard case .step(_, let verified, let reason) = records[1] else { Issue.record("\(records)"); return }
            #expect(verified, Comment(rawValue: reason))
            let taps = await driver.capturedActions.filter { $0.hasPrefix("tap(") }
            #expect(taps.count == 1)
        }
        // Case FALSE: Portfolio absent, More present
        do {
            let driver = SimulatedDriver(currentSnapshot: Self.obs([Self.el("button", label: "More")]))
            await driver.queueNextSnapshot(Self.obs([Self.el("staticText", id: "more_screen")]))
            let (records, _) = try await IRTestRunner.run([Self.portfolioBranchStep()], verdicts: Self.verdicts(for: [Self.portfolioBranchStep()]), testKey: "GENERIC-2", title: "g2",
                                                            credentials: [:], driver: driver, toolRegistry: Self.toolRegistry(driver))
            guard case .branchSelected(_, .else, _) = records[0] else { Issue.record("\(records)"); return }
            guard case .step(let id, let verified, let reason) = records[1] else { Issue.record("\(records)"); return }
            #expect(id == "g2-else-more")
            #expect(verified, Comment(rawValue: reason))
            let taps = await driver.capturedActions.filter { $0.hasPrefix("tap(") }
            #expect(taps.count == 1)
        }
    }

    // MARK: - Generic example 3: AND-composed condition, unrelated to Collection

    static func andBranchStep() -> IRStep {
        IRStep(id: "g3-branch", sourceStepNumber: 3, intent: "if A and B both exist, run path A, else path B", action: .verifyOnly,
               branch: IRBranch(
                   condition: .all([.elementExists(IRTarget(role: "button", identifier: "elementA")), .elementExists(IRTarget(role: "button", identifier: "elementB"))]),
                   thenSteps: [IRStep(id: "g3-then-pathA", sourceStepNumber: 3, intent: "run path A", action: .tap,
                                       target: IRTarget(role: "button", identifier: "elementA"),
                                       verification: IRVerification(description: "path A ran", requiredElements: [ScenarioExpectedElement(role: "staticText", identifier: "path_a_marker")]))],
                   elseSteps: [IRStep(id: "g3-else-pathB", sourceStepNumber: 3, intent: "run path B", action: .tap,
                                       target: IRTarget(role: "button", identifier: "elementB_fallback"),
                                       verification: IRVerification(description: "path B ran", requiredElements: [ScenarioExpectedElement(role: "staticText", identifier: "path_b_marker")]))]))
    }

    @Test("Generic example 3 (A AND B): both present -> path A; only one present -> path B (AND composition affects the outcome)")
    @MainActor
    func testGenericExample3AndComposition() async throws {
        // Both A and B present -> path A
        do {
            let driver = SimulatedDriver(currentSnapshot: Self.obs([Self.el("button", id: "elementA"), Self.el("button", id: "elementB")]))
            await driver.queueNextSnapshot(Self.obs([Self.el("staticText", id: "path_a_marker")]))
            let (records, _) = try await IRTestRunner.run([Self.andBranchStep()], verdicts: Self.verdicts(for: [Self.andBranchStep()]), testKey: "GENERIC-3", title: "g3",
                                                            credentials: [:], driver: driver, toolRegistry: Self.toolRegistry(driver))
            guard case .branchSelected(_, .then, _) = records[0] else { Issue.record("\(records)"); return }
            guard case .step(let id, let verified, let reason) = records[1] else { Issue.record("\(records)"); return }
            #expect(id == "g3-then-pathA")
            #expect(verified, Comment(rawValue: reason))
        }
        // Only A present (B absent, but a decoy "elementB_fallback" exists) -> AND is false -> path B
        do {
            let driver = SimulatedDriver(currentSnapshot: Self.obs([Self.el("button", id: "elementA"), Self.el("button", id: "elementB_fallback")]))
            await driver.queueNextSnapshot(Self.obs([Self.el("staticText", id: "path_b_marker")]))
            let (records, _) = try await IRTestRunner.run([Self.andBranchStep()], verdicts: Self.verdicts(for: [Self.andBranchStep()]), testKey: "GENERIC-3", title: "g3",
                                                            credentials: [:], driver: driver, toolRegistry: Self.toolRegistry(driver))
            guard case .branchSelected(_, .else, _) = records[0] else { Issue.record("\(records)"); return }
            guard case .step(let id, let verified, let reason) = records[1] else { Issue.record("\(records)"); return }
            #expect(id == "g3-else-pathB")
            #expect(verified, Comment(rawValue: reason))
            // Path A's target (elementA) exists in this observation, but path A never dispatched (an
            // ordinary single-condition check would have wrongly taken it; the AND composition forbids it).
            let taps = await driver.capturedActions.filter { $0.contains("elementA") }
            #expect(taps.isEmpty)
        }
    }

    // MARK: - Nested branch

    @Test("Nested branch: outer TRUE + inner FALSE selects the inner else arm, never the inner then arm")
    @MainActor
    func testNestedBranch() async throws {
        let inner = IRStep(id: "nested-inner", sourceStepNumber: 4, intent: "inner decision", action: .verifyOnly,
                            branch: IRBranch(
                                condition: .elementExists(IRTarget(role: "button", identifier: "inner_target")),
                                thenSteps: [IRStep(id: "nested-inner-then", sourceStepNumber: 4, intent: "inner then", action: .tap, target: IRTarget(role: "button", identifier: "inner_then_button"))],
                                elseSteps: [IRStep(id: "nested-inner-else", sourceStepNumber: 4, intent: "inner else", action: .tap, target: IRTarget(role: "button", identifier: "inner_else_button"),
                                                    verification: IRVerification(description: "inner else ran", requiredElements: [ScenarioExpectedElement(role: "staticText", identifier: "inner_else_marker")]))]))
        let outer = IRStep(id: "nested-outer", sourceStepNumber: 4, intent: "outer decision", action: .verifyOnly,
                            branch: IRBranch(condition: .elementExists(IRTarget(role: "button", identifier: "outer_target")),
                                              thenSteps: [inner], elseSteps: []))

        let driver = SimulatedDriver(currentSnapshot: Self.obs([
            Self.el("button", id: "outer_target"),   // outer condition TRUE
            Self.el("button", id: "inner_else_button")
            // no "inner_target" -> inner condition FALSE -> inner else arm
        ]))
        await driver.queueNextSnapshot(Self.obs([Self.el("staticText", id: "inner_else_marker")]))

        let (records, _) = try await IRTestRunner.run([outer], verdicts: Self.verdicts(for: [outer]), testKey: "NESTED", title: "nested",
                                                        credentials: [:], driver: driver, toolRegistry: Self.toolRegistry(driver))
        #expect(records.count == 3) // outer selection, inner selection, inner-else step
        guard case .branchSelected(let id0, let arm0, _) = records[0] else { Issue.record("\(records)"); return }
        #expect(id0 == "nested-outer" && arm0 == .then)
        guard case .branchSelected(let id1, let arm1, _) = records[1] else { Issue.record("\(records)"); return }
        #expect(id1 == "nested-inner" && arm1 == .else)
        guard case .step(let stepID, let verified, let reason) = records[2] else { Issue.record("\(records)"); return }
        #expect(stepID == "nested-inner-else")
        #expect(verified, Comment(rawValue: reason))
        let taps = await driver.capturedActions.filter { $0.contains("inner_then_button") }
        #expect(taps.isEmpty, "the inner THEN arm must never run when the inner condition is false")
    }

    // MARK: - HITL: branch selection never auto-approves the chosen arm's first step

    @Test("Selecting a branch arm still stops at a pending approval; nothing dispatches until the test explicitly approves")
    @MainActor
    func testBranchSelectionNeverAutoApproves() throws {
        let placeholder = ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button"))
        let scenario = SafeScenario(id: "HITL-1", name: "hitl", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: placeholder)
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        let executor = TestIRExecutor(controller: controller)

        let branch = Self.loginBranchStep(thenVerifyTarget: "Home").branch!
        let obs = Self.obs([Self.el("button", id: "login_button")])
        guard case .selected(.then, _) = executor.evaluateBranch(branch, freshObservation: obs) else { Issue.record("expected THEN"); return }

        // Compile and start just the then-arm, then propose its first (only) step.
        let armScenario = try #require(TestIRExecutor.compileLinearScenario(testKey: "HITL-1", title: "hitl", steps: branch.thenSteps, verdicts: ["g1-then-tap": .admitted]))
        #expect(controller.startScenario(armScenario))
        guard case .pending(let approval) = executor.proposeCurrentStep(freshObservation: obs) else { Issue.record("expected a pending approval"); return }

        #expect(approval.status == .pending)
        #expect(controller.activeApproval?.status == .pending)
        #expect(controller.stepLifecycle != .actionExecuting)
    }

    // MARK: - Freshness: a stale observation cannot drive the chosen arm past admission

    @Test("A stale observation, reused after the driver's real state has moved on, fails at the driver boundary — not silently accepted")
    @MainActor
    func testStaleObservationFailsAtDriverBoundary() async throws {
        let branchStep = Self.portfolioBranchStep()
        let placeholder = ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button"))
        let scenario = SafeScenario(id: "FRESH-1", name: "fresh", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: placeholder)
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        let executor = TestIRExecutor(controller: controller)

        // The observation used to decide the branch: Portfolio absent -> ELSE (More) selected.
        let staleObservation = Self.obs([Self.el("button", label: "More")], id: "snap_stale")
        guard case .selected(.else, _) = executor.evaluateBranch(branchStep.branch!, freshObservation: staleObservation) else {
            Issue.record("expected ELSE"); return
        }

        // Between deciding the branch and acting on it, the real device moved on to a genuinely different
        // snapshot (a different snapshotID) — exactly what a live driver would report after any real delay.
        let driver = SimulatedDriver(currentSnapshot: Self.obs([Self.el("button", label: "More")], id: "snap_current"))

        // Wrongly reusing the stale observation object (instead of the driver's real current snapshot) to
        // propose and dispatch the chosen arm's first step must fail at the driver's own ground-truth check.
        let armScenario = try #require(TestIRExecutor.compileLinearScenario(testKey: "FRESH-1", title: "fresh", steps: branchStep.branch!.elseSteps, verdicts: ["g2-else-more": .admitted]))
        #expect(controller.startScenario(armScenario))
        guard case .pending = executor.proposeCurrentStep(freshObservation: staleObservation) else { Issue.record("admission itself is internally self-consistent and should still admit"); return }
        controller.approveCurrentStep(source: .testAuthority)

        let result = await controller.dispatchCurrentStep(driver: driver, toolRegistry: Self.toolRegistry(driver))
        guard case .failure(let error) = result else { Issue.record("dispatching against the stale snapshot must fail, not succeed: \(result)"); return }
        guard case .staleSnapshot = error else { Issue.record("expected a staleSnapshot failure, got \(error)"); return }
        // The gesture was attempted (the mock records the attempt before checking freshness) but the
        // element itself was never actually resolved/tapped against real device state: no successful
        // tap-completion is recorded beyond the one refused attempt.
        #expect((await driver.invokedActionCount["tap"] ?? 0) == 1)
        #expect((await driver.capturedActions.filter { $0.hasPrefix("tap(") }.count) == 1)
    }
}
