import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Generic simulated driver for a `TestIR` step list, reused by every branch-execution test — the DEMO-TC-872
/// proving case and the unrelated generic examples alike. It contains no test-case-specific logic: it only
/// walks `TestIRExecutor.nextSegment` and, for a linear run, proposes/approves/dispatches each compiled step
/// through the real `ScenarioExecutionController`; for a branch, evaluates it and recurses into the selected
/// arm. Approving and dispatching happen here (in `Tests/`, never scanned by the architecture audits),
/// exactly mirroring how `ValidEndToEndProposalTests` simulates a human supervisor via `AgentUIState`.
enum IRTestRunner {
    enum SegmentRecord: Equatable {
        case step(id: String, verified: Bool, reason: String)
        case branchSelected(stepID: String, arm: IRBranchArm, snapshotID: String)
        case branchIndeterminate(stepID: String, reason: String)
        case skippedUnadmitted
    }

    enum RunnerError: Error { case notAdmitted(stepID: String), failedToStart }

    /// Runs `steps` to completion (or until an indeterminate branch halts it). `driver.currentSnapshot` is
    /// read fresh before every proposal and every branch decision — the caller controls freshness entirely
    /// by queuing snapshots on `driver` (`queueNextSnapshot`) before each dispatch, exactly as the linear
    /// round-trip test in the previous phase already did.
    @MainActor
    static func run(
        _ steps: [IRStep], verdicts: [String: IRStepVerdict], testKey: String, title: String,
        credentials: [String: String], driver: SimulatedDriver, toolRegistry: ToolRegistry
    ) async throws -> (records: [SegmentRecord], controller: ScenarioExecutionController) {
        let placeholder = ScenarioStep(id: "placeholder", name: "placeholder", description: "placeholder",
                                        toolName: "tap_element", locator: ScenarioLocator(role: "button"))
        let placeholderScenario = SafeScenario(
            id: testKey, name: title, purpose: "IR test runner placeholder (bookkeeping only; the step actually checked at every stage is always the explicit compiled step).",
            initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: placeholder
        )
        let catalog = ScenarioCatalog(scenarios: [placeholderScenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))

        var records: [SegmentRecord] = []
        var remaining = steps
        while true {
            switch TestIRExecutor.nextSegment(remaining) {
            case .done:
                return (records, controller)

            case .branch(let branch, let stepID, let rest):
                let observation = await driver.currentSnapshot
                let executor = TestIRExecutor(controller: controller)
                switch executor.evaluateBranch(branch, freshObservation: observation) {
                case .selected(let arm, let snapshotID):
                    records.append(.branchSelected(stepID: stepID, arm: arm, snapshotID: snapshotID))
                    remaining = (arm == .then ? branch.thenSteps : branch.elseSteps) + rest
                case .indeterminate(let reason):
                    records.append(.branchIndeterminate(stepID: stepID, reason: reason))
                    return (records, controller)
                }

            case .linear(let segmentSteps, let rest):
                let executor = TestIRExecutor(controller: controller)
                for step in segmentSteps {
                    guard case .admitted = verdicts[step.id] else { records.append(.skippedUnadmitted); continue }

                    // A verifyOnly step has no device action and no target to resolve: it is decided the
                    // same way a branch is, a pure check against the observation already in hand — never a
                    // new ActionProposal/approval/dispatch cycle (there is nothing to approve).
                    if step.action == .verifyOnly {
                        let observation = await driver.currentSnapshot
                        guard let result = executor.evaluateVerifyOnly(step, freshObservation: observation) else {
                            records.append(.skippedUnadmitted); continue
                        }
                        records.append(.step(id: step.id, verified: result.verified, reason: result.reason))
                        continue
                    }

                    guard let scenario = TestIRExecutor.compileLinearScenario(
                        testKey: testKey, title: title, steps: [step], verdicts: verdicts, credentials: credentials
                    ) else {
                        records.append(.skippedUnadmitted)
                        continue
                    }
                    guard controller.startScenario(scenario) else { throw RunnerError.failedToStart }
                    let observation = await driver.currentSnapshot
                    guard case .pending = executor.proposeCurrentStep(freshObservation: observation) else {
                        throw RunnerError.notAdmitted(stepID: step.id)
                    }
                    controller.approveCurrentStep(source: .testAuthority)
                    switch await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry) {
                    case .success(let verification): records.append(.step(id: step.id, verified: verification.verified, reason: verification.reason))
                    case .failure(let error): throw error
                    }
                }
                remaining = rest
            }
        }
    }

    /// IR-execution contract: like `run`, but the pre/post observation for every step is synthesized generically by
    /// `IRAutoObserver` from the step's own (already-validated) locator/verification/signals, instead of
    /// being pre-scripted by the caller. This is what makes it possible to drive **arbitrary** IR — the full
    /// 55-step DEMO-TC-872 fixture in one pass, or real (not-known-ahead-of-time) LLM output — through the
    /// real trusted spine without hand-authoring an `Observation` for every step. Still the same pipeline:
    /// `nextSegment` -> propose/approve/dispatch or evaluateBranch/evaluateVerifyOnly -> `ScenarioVerificationService`.
    ///
    /// - Parameter branchSatisfied: which arm every branch encountered should take (best-effort — see
    ///   `IRAutoObserver.elements(satisfying:satisfied:)`); real per-branch coverage is `run`'s job (already
    ///   proven per-branch in `TestIRBranchExecutionTests`), not this generic pass's.
    @MainActor
    static func runAutoObserved(
        _ steps: [IRStep], verdicts: [String: IRStepVerdict], testKey: String, title: String,
        credentials: [String: String], driver: SimulatedDriver, toolRegistry: ToolRegistry, branchSatisfied: Bool = false
    ) async throws -> (records: [SegmentRecord], unsatisfiableSignals: [String: [String]], controller: ScenarioExecutionController) {
        let placeholder = ScenarioStep(id: "placeholder", name: "placeholder", description: "placeholder",
                                        toolName: "tap_element", locator: ScenarioLocator(role: "button"))
        let placeholderScenario = SafeScenario(
            id: testKey, name: title, purpose: "IR auto-observed test runner placeholder (bookkeeping only).",
            initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: placeholder
        )
        let catalog = ScenarioCatalog(scenarios: [placeholderScenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))

        var records: [SegmentRecord] = []
        var unsatisfiable: [String: [String]] = [:]
        var remaining = steps
        var counter = 0

        while true {
            switch TestIRExecutor.nextSegment(remaining) {
            case .done:
                return (records, unsatisfiable, controller)

            case .branch(let branch, let stepID, let rest):
                counter += 1
                let conditionElements = IRAutoObserver.elements(satisfying: branch.condition, satisfied: branchSatisfied)
                let conditionAppState = IRAutoObserver.appState(for: branch.condition, satisfied: branchSatisfied)
                let observation = Observation(snapshotID: "auto_branch_\(counter)", bundleID: "com.apple.mobilesafari", appState: conditionAppState, elements: conditionElements)
                await driver.setSnapshot(observation)
                let executor = TestIRExecutor(controller: controller)
                switch executor.evaluateBranch(branch, freshObservation: observation) {
                case .selected(let arm, let snapshotID):
                    records.append(.branchSelected(stepID: stepID, arm: arm, snapshotID: snapshotID))
                    remaining = (arm == .then ? branch.thenSteps : branch.elseSteps) + rest
                case .indeterminate(let reason):
                    records.append(.branchIndeterminate(stepID: stepID, reason: reason))
                    return (records, unsatisfiable, controller)
                }

            case .linear(let segmentSteps, let rest):
                let executor = TestIRExecutor(controller: controller)
                for step in segmentSteps {
                    guard case .admitted = verdicts[step.id] else { records.append(.skippedUnadmitted); continue }
                    counter += 1

                    if step.action == .verifyOnly {
                        guard case .compiled(let compiled) = TestIRCompiler.compile(step, credentials: credentials) else {
                            records.append(.skippedUnadmitted); continue
                        }
                        let observation = IRAutoObserver.observationForVerifyOnly(compiled.scenarioStep, idPrefix: "auto_\(counter)")
                        await driver.setSnapshot(observation)
                        guard let result = executor.evaluateVerifyOnly(step, freshObservation: observation) else {
                            records.append(.skippedUnadmitted); continue
                        }
                        records.append(.step(id: step.id, verified: result.verified, reason: result.reason))
                        continue
                    }

                    guard case .compiled(let compiled) = TestIRCompiler.compile(step, credentials: credentials) else {
                        records.append(.skippedUnadmitted); continue
                    }
                    guard let scenario = TestIRExecutor.compileLinearScenario(
                        testKey: testKey, title: title, steps: [step], verdicts: verdicts, credentials: credentials
                    ) else {
                        records.append(.skippedUnadmitted); continue
                    }
                    guard controller.startScenario(scenario) else { throw RunnerError.failedToStart }

                    let (pre, post, honestlyUnsatisfiable) = IRAutoObserver.observationPair(for: compiled.scenarioStep, idPrefix: "auto_\(counter)")
                    if !honestlyUnsatisfiable.isEmpty { unsatisfiable[step.id] = honestlyUnsatisfiable }
                    await driver.setSnapshot(pre)
                    guard case .pending = executor.proposeCurrentStep(freshObservation: pre) else {
                        throw RunnerError.notAdmitted(stepID: step.id)
                    }
                    controller.approveCurrentStep(source: .testAuthority)
                    await driver.queueNextSnapshot(post)
                    switch await controller.dispatchCurrentStep(driver: driver, toolRegistry: toolRegistry) {
                    case .success(let verification): records.append(.step(id: step.id, verified: verification.verified, reason: verification.reason))
                    case .failure(let error): throw error
                    }
                }
                remaining = rest
            }
        }
    }
}
