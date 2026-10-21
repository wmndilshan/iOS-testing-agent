import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix, Categories H (Branch Failure) and I (Nested Branch Depth). `TestIRExecutor.evaluateBranch`
/// and `StatefulScenarioRunner.driveSteps` (both unmodified since Nested-branch contract) are exercised directly —
/// proving indeterminate conditions never select an arm, a malformed UNSELECTED arm is never even looked
/// at, a fabricated SELECTED arm target is blocked before dispatch, and forged/stale branch data can never
/// influence which arm runs. Depth-limit boundary certification (levels 4 accepted / 5 rejected) already
/// has dedicated coverage in `NestedBranchExecutionTests` and `MalformedIRFaultTests` (decoder path);
/// this file does not repeat it.
@Suite("Fault-injection matrix.H Branch Fault Injection")
@MainActor
struct BranchFaultTests {
    static func rig(scenarioID: String) -> (FaultInjectingXCTestDriver, ToolRegistry, ScenarioExecutionController) {
        let obs = Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [])
        let mock = SimulatedDriver(currentSnapshot: obs)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: scenarioID, name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                                                actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        return (driver, registry, controller)
    }

    @Test("An outer condition that matches 2+ real elements (ambiguous) is indeterminate — no arm is selected, no arm's steps are ever touched")
    func testAmbiguousOuterConditionNeverSelectsAnArm() async throws {
        let obs = Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "button", label: "Dup"),
            UIElementSnapshot(id: "e2", role: "button", label: "Dup")
        ])
        let mock2 = SimulatedDriver(currentSnapshot: obs)
        let driver2 = FaultInjectingXCTestDriver(inner: mock2)
        let branch = IRBranch(condition: .elementExists(IRTarget(role: "button", label: "Dup")),
                               thenSteps: [IRStep(id: "then1", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "Dup"))],
                               elseSteps: [IRStep(id: "else1", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "Dup"))])
        let step = IRStep(id: "outer", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: branch)
        let validation = TestIRValidator.validate(TestIR(testKey: "BR-1", title: "t", steps: [step]))
        #expect(validation.isAccepted)

        let registry2 = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver2)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "BR-1", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                                                actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller2 = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        await driver2.queueObservations([obs])

        var threw = false
        do {
            _ = try await StatefulScenarioRunner.driveSteps([step], verdicts: validation.stepVerdicts, testKey: "BR-1", title: "t",
                                                             driver: driver2, registry: registry2, controller: controller2, bundleID: "com.autonomous.agent.fixture")
        } catch { threw = true }
        #expect(threw, "an indeterminate condition must halt execution, never guess an arm")
        let mutationCount = await driver2.mutationCallCount
        #expect(mutationCount == 0, "neither arm's tap ('Dup') may ever be dispatched when the condition itself is indeterminate")
    }

    @Test("An inner (nested) condition that is indeterminate halts at that level — the outer arm was correctly selected, but no inner arm ever runs")
    func testAmbiguousInnerConditionHaltsAfterCorrectOuterSelection() async throws {
        let obs = Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "outer", role: "other", label: "outerTrue"),
            UIElementSnapshot(id: "i1", role: "other", label: "ambiguousInner"),
            UIElementSnapshot(id: "i2", role: "other", label: "ambiguousInner"),
        ])
        let inner = IRBranch(condition: .elementExists(IRTarget(role: "other", label: "ambiguousInner")),
                              thenSteps: [IRStep(id: "x", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "X"))],
                              elseSteps: [IRStep(id: "y", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "Y"))])
        let outer = IRBranch(condition: .elementExists(IRTarget(role: "other", label: "outerTrue")),
                              thenSteps: [IRStep(id: "inner", sourceStepNumber: 1, intent: "inner", action: .verifyOnly, branch: inner)],
                              elseSteps: [IRStep(id: "z", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "Z"))])
        let step = IRStep(id: "outer_step", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: outer)
        let validation = TestIRValidator.validate(TestIR(testKey: "BR-2", title: "t", steps: [step]))
        #expect(validation.isAccepted)

        let mock = SimulatedDriver(currentSnapshot: obs)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        await driver.queueObservations(Array(repeating: obs, count: 6))
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "BR-2", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                                                actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))

        var threw = false
        do {
            _ = try await StatefulScenarioRunner.driveSteps([step], verdicts: validation.stepVerdicts, testKey: "BR-2", title: "t",
                                                             driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        } catch { threw = true }
        #expect(threw, "the inner indeterminate condition must halt execution")
        // Neither X, Y (inner arms) nor Z (outer else, correctly never reached since outer was TRUE) may ever dispatch.
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0)
    }

    @Test("A fabricated target inside the SELECTED arm is blocked by grounding before dispatch; a malformed target in the UNSELECTED arm is never even looked at (never grounded, never validated against reality, never dispatched)")
    func testSelectedArmFabricationBlockedUnselectedArmNeverTouched() async throws {
        let obs = Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "outer", role: "other", label: "outerTrue"),
            UIElementSnapshot(id: "y", role: "button", label: "Y")
        ])
        // THEN (selected, since outerTrue is observed) names a target that does not exist ("GhostX").
        // ELSE (never selected) names an equally fake target ("GhostZ") — if the runtime ever touched it,
        // grounding would also reject it, but the whole point is it must never even be asked to.
        let branch = IRBranch(condition: .elementExists(IRTarget(role: "other", label: "outerTrue")),
                               thenSteps: [IRStep(id: "then1", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "GhostX"))],
                               elseSteps: [IRStep(id: "else1", sourceStepNumber: 1, intent: "i", action: .tap, target: IRTarget(role: "button", label: "GhostZ"))])
        let step = IRStep(id: "outer_step", sourceStepNumber: 1, intent: "outer", action: .verifyOnly, branch: branch)
        let validation = TestIRValidator.validate(TestIR(testKey: "BR-3", title: "t", steps: [step]))
        #expect(validation.isAccepted, "both arms are structurally legal IR — the fabrication is only discoverable by grounding against reality")

        let mock = SimulatedDriver(currentSnapshot: obs)
        let driver = FaultInjectingXCTestDriver(inner: mock)
        await driver.queueObservations(Array(repeating: obs, count: 6))
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "BR-3", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                                                actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))

        var threw = false
        do {
            _ = try await StatefulScenarioRunner.driveSteps([step], verdicts: validation.stepVerdicts, testKey: "BR-3", title: "t",
                                                             driver: driver, registry: registry, controller: controller, bundleID: "com.autonomous.agent.fixture")
        } catch { threw = true }
        #expect(threw, "the selected THEN arm's fabricated target must block via grounding")
        let mutationCount = await driver.mutationCallCount
        #expect(mutationCount == 0, "GhostX (selected, fabricated) is blocked before dispatch; GhostZ (unselected) is never even reached to be blocked or dispatched")
    }

    @Test("Forged branch-selection evidence fields have zero effect on which arm actually runs — evaluateBranch's own outcome is the only thing StatefulScenarioRunner ever acts on")
    func testForgedSelectionCannotOverrideRealEvaluation() {
        let obsElseTrue = Observation(bundleID: "com.autonomous.agent.fixture", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "other", label: "absent-marker-not-here")
        ])
        let branch = IRBranch(condition: .elementExists(IRTarget(role: "other", label: "outerTrue")), thenSteps: [], elseSteps: [])
        let catalog = ScenarioCatalog(scenarios: [SafeScenario(id: "BR-4", name: "n", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true,
                                                                actionStep: ScenarioStep(id: "placeholder", name: "p", description: "p", toolName: "tap_element", locator: ScenarioLocator(role: "button")))])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        let executor = TestIRExecutor(controller: controller)
        // Whatever an attacker/LLM might have "claimed" about this branch (there is no field on IRBranch or
        // IRStep to even carry such a claim — see `TestIRSecurityTests`'s "Fault E" test), the ONLY input
        // `evaluateBranch` ever reads is the real, freshly-observed element set.
        let outcome = executor.evaluateBranch(branch, freshObservation: obsElseTrue)
        guard case .selected(let arm, _) = outcome else { Issue.record("expected a determinate selection"); return }
        #expect(arm == .else, "the real observation has no 'outerTrue' element — the ONLY correct, honest outcome is ELSE, regardless of anything else")
    }
}
