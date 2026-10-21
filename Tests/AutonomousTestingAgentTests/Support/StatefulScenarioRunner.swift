import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Stateful-scenario contract/48/49: drives a NATURAL-LANGUAGE multi-step scenario, one step at a time, through the EXISTING
/// trusted pipeline — never a second execution engine. Each scenario-level NL step:
///   1. captures a FRESH observation (never reuses an earlier step's vocabulary — Part E, step-local grounding)
///   2. derives `ObservedUIVocabulary` from it
///   3. calls the real `GroundedTestIRGeneration.generate` (Regeneration contract's own bounded 3-attempt
///      generate→validate→ground→regenerate loop) for JUST that step's NL text
///   4. if blocked (ungrounded after 3 attempts), the WHOLE scenario stops here — no downstream step is
///      ever attempted (Part M)
///   5. if accepted, drives the resulting IR through `driveSteps` — which walks `TestIRExecutor
///      .nextSegment` exactly like `IRTestRunner.run` does (Adversarial-IR contract), RECURSIVELY (Nested-branch contract): a `.linear`
///      segment is grounded against a FRESH observation captured right then, then dispatched
///      (propose→HITL→approve→dispatch→fresh-post-observation→verify); a `.branch` segment evaluates its
///      condition against a FRESH observation, selects an arm from the runtime's own decision (never the
///      LLM's say-so), and feeds that arm's steps back into the SAME loop — so a nested branch inside a
///      selected arm is handled by the identical mechanism, at any depth, never a second engine. Generic
///      over `any DeviceDriver` so the same code path serves both the live suite
///      (`SimulatorXCTestDriver`) and deterministic tests (`SimulatedDriver`).
///   6. captures a fresh post-step observation for evidence (Part G's preSnapshotID/postSnapshotID)
///   7. if the step's own verification failed, the scenario also stops (an unverified action makes every
///      later "fresh observation" reflect an unknown state — continuing would be unsafe, not merely unwise)
///
/// This file is pure test/harness composition (mirrors `IRTestRunner`'s own placement) — no production
/// code, no new trusted call sites; `driveLinearSegment` remains the only place in this file that ever
/// calls `controller.dispatchCurrentStep`, identically to every prior phase's live tests.
enum StatefulScenarioRunner {
    enum StepOutcome: String, Sendable, Equatable {
        case completed = "COMPLETED"
        case blocked = "BLOCKED"
        case notExecuted = "NOT_EXECUTED"
    }

    /// Branch/regeneration contract/49: branch-specific evidence for ONE branch level. Records the runtime's own condition
    /// decision — never anything the LLM claimed. A nested-branch run produces one of these per level
    /// encountered, in outer-to-inner order.
    struct BranchEvidence: Sendable {
        let depth: Int // 0 = outermost branch encountered in this step's IR
        let conditionResult: String // "satisfied" | "notSatisfied" | "indeterminate"
        let selectedArm: String?    // "then" | "else" | nil (indeterminate)
        let unselectedArm: String?
        let conditionSnapshotID: String
    }

    struct StepEvidence: Sendable {
        let stepIndex: Int
        let stepDescription: String
        let outcome: StepOutcome
        let generationID: String?
        let resultKind: GroundedGenerationResultKind?
        let attemptCount: Int?
        let preSnapshotID: String?
        let postSnapshotID: String?
        let groundingBlockingReasons: [String]
        let verified: Bool?
        let verificationReason: String?
        var branches: [BranchEvidence] = []
        /// Backward-compatible accessor for the outermost branch (Branch/regeneration contract's own evidence shape) — `nil`
        /// when this step's IR had no branch at all.
        var branch: BranchEvidence? { branches.first }
    }

    struct ScenarioEvidence: Sendable {
        let scenarioID: String
        var steps: [StepEvidence] = []
        var isFullyCompleted: Bool { steps.allSatisfy { $0.outcome == .completed } }
    }

    /// One non-branching run of admitted steps: propose→HITL→approve→dispatch→verify. Identical shape to
    /// `IRTestRunner.run`'s own linear-segment handling, generic over `any DeviceDriver`. Grounding
    /// happens in the CALLER (`driveSteps`), against a freshly captured observation, immediately before
    /// this is invoked — never here, and never reused from an earlier segment.
    @MainActor
    private static func driveLinearSegment(
        _ steps: [IRStep], verdicts: [String: IRStepVerdict], testKey: String, title: String,
        driver: any DeviceDriver, registry: ToolRegistry, controller: ScenarioExecutionController, bundleID: String
    ) async throws -> [IRTestRunner.SegmentRecord] {
        var records: [IRTestRunner.SegmentRecord] = []
        let executor = TestIRExecutor(controller: controller)
        for step in steps {
            guard case .admitted = verdicts[step.id] else { records.append(.skippedUnadmitted); continue }

            if step.action == .verifyOnly {
                let obs = try await driver.captureObservation(bundleID: bundleID)
                guard let result = executor.evaluateVerifyOnly(step, freshObservation: obs) else { records.append(.skippedUnadmitted); continue }
                records.append(.step(id: step.id, verified: result.verified, reason: result.reason))
                continue
            }

            guard let scenario = TestIRExecutor.compileLinearScenario(testKey: testKey, title: title, steps: [step], verdicts: verdicts, credentials: [:]) else {
                records.append(.skippedUnadmitted); continue
            }
            guard controller.startScenario(scenario) else { throw IRTestRunner.RunnerError.failedToStart }
            let pre = try await driver.captureObservation(bundleID: bundleID)
            guard case .pending = executor.proposeCurrentStep(freshObservation: pre) else {
                throw IRTestRunner.RunnerError.notAdmitted(stepID: step.id)
            }
            controller.approveCurrentStep(source: .testAuthority)
            switch await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: bundleID, isLive: false) {
            case .success(let verification): records.append(.step(id: step.id, verified: verification.verified, reason: verification.reason))
            case .failure(let error): throw error
            }
        }
        return records
    }

    /// Branch/regeneration contract/49: walks `TestIRExecutor.nextSegment`. A `.linear` segment is grounded against a FRESH
    /// observation captured right here (never a stale/earlier one, and never one skipped merely because an
    /// outer branch already grounded something), then dispatched. A `.branch` segment evaluates its
    /// condition against a FRESH observation, selects the runtime's OWN arm (Part K/Part B of Nested-branch contract: no
    /// LLM/cache override possible), records evidence for that level, and feeds the selected arm's steps
    /// back into `remaining` — so the very next loop iteration grounds/dispatches that arm's own linear
    /// prefix, or, if the arm itself starts with a NESTED branch, recurses into evaluating THAT condition
    /// fresh, at any depth. The unselected arm's steps are never touched at all — not grounded, not walked,
    /// not looked at.
    @MainActor
    static func driveSteps(
        _ steps: [IRStep], verdicts: [String: IRStepVerdict], testKey: String, title: String,
        driver: any DeviceDriver, registry: ToolRegistry, controller: ScenarioExecutionController, bundleID: String
    ) async throws -> (records: [IRTestRunner.SegmentRecord], branches: [BranchEvidence]) {
        var allRecords: [IRTestRunner.SegmentRecord] = []
        var branchEvidences: [BranchEvidence] = []
        var remaining = steps

        while true {
            switch TestIRExecutor.nextSegment(remaining) {
            case .done:
                return (allRecords, branchEvidences)

            case .linear(let segmentSteps, let rest):
                // Ground THIS segment against a FRESH observation, captured now — never reused from an
                // earlier segment or an outer branch's condition-evaluation observation. A step that only
                // becomes targetable after an earlier segment's/arm's action has run is correctly grounded
                // against the state that action produced, never against a stale, pre-action vocabulary.
                let obs = try await driver.captureObservation(bundleID: bundleID)
                let vocabulary = ObservedUIVocabulary.derive(from: obs)
                let grounding = ObservationGroundingService.groundSteps(segmentSteps, vocabulary: vocabulary)
                guard grounding.isFullyGrounded else {
                    throw IRTestRunner.RunnerError.notAdmitted(stepID: "segment-ungrounded:\(grounding.blockingIssues.map(\.description).joined(separator: "; "))")
                }
                let records = try await driveLinearSegment(segmentSteps, verdicts: verdicts, testKey: testKey, title: title,
                                                            driver: driver, registry: registry, controller: controller, bundleID: bundleID)
                allRecords.append(contentsOf: records)
                remaining = rest

            case .branch(let branch, let sourceStepID, let rest):
                // Part G/L/J: the condition is decided from a FRESH observation captured right now — never
                // the step-generation-time vocabulary, never an outer branch's own condition observation,
                // never anything cached.
                let conditionObs = try await driver.captureObservation(bundleID: bundleID)
                let executor = TestIRExecutor(controller: controller)
                let outcome = executor.evaluateBranch(branch, freshObservation: conditionObs)
                let depth = branchEvidences.count

                switch outcome {
                case .indeterminate(let reason):
                    branchEvidences.append(BranchEvidence(depth: depth, conditionResult: "indeterminate", selectedArm: nil, unselectedArm: nil, conditionSnapshotID: conditionObs.snapshotID))
                    throw IRTestRunner.RunnerError.notAdmitted(stepID: "\(sourceStepID)-indeterminate:\(reason)")

                case .selected(let arm, let snapshotID):
                    let armSteps = arm == .then ? branch.thenSteps : branch.elseSteps
                    // `TestIRExecutor.evaluateBranch` selects `.then` exactly when the condition evaluated
                    // `.satisfied`, and `.else` exactly when `.notSatisfied` — the arm IS the condition
                    // result, restated for evidence.
                    branchEvidences.append(BranchEvidence(
                        depth: depth,
                        conditionResult: arm == .then ? "satisfied" : "notSatisfied",
                        selectedArm: arm == .then ? "then" : "else",
                        unselectedArm: arm == .then ? "else" : "then",
                        conditionSnapshotID: snapshotID))

                    // Part B/D: recurse through the SAME loop — the selected arm's own linear prefix will be
                    // grounded (against a fresh observation) and dispatched by the `.linear` case above; if
                    // the arm itself starts with a NESTED branch, the `.branch` case handles it identically,
                    // at any depth. The UNselected arm (`branch.elseSteps`/`branch.thenSteps`, whichever was
                    // not chosen) is never referenced again — never grounded, never walked, never dispatched.
                    remaining = armSteps + rest
                }
            }
        }
    }

    @MainActor
    static func run(
        scenarioID: String,
        stepNLTexts: [String],
        generator: TestIRGenerator,
        driver: any DeviceDriver,
        registry: ToolRegistry,
        controller: ScenarioExecutionController,
        bundleID: String
    ) async throws -> ScenarioEvidence {
        var evidence = ScenarioEvidence(scenarioID: scenarioID)

        for (index, nl) in stepNLTexts.enumerated() {
            let stepNumber = index + 1
            let stepKey = "\(scenarioID)-S\(stepNumber)"

            // Part E: step-local grounding — a FRESH observation/vocabulary, never a prior step's.
            let pre = try await driver.captureObservation(bundleID: bundleID)
            let vocabulary = ObservedUIVocabulary.derive(from: pre)

            let (outcome, genEvidence) = await GroundedTestIRGeneration.generate(
                using: generator, testKey: stepKey, title: "Stateful-scenario contract/48/49 step \(stepNumber)", stepsText: nl, vocabulary: vocabulary)

            guard case .accepted(let ir, _) = outcome else {
                var reasons: [String] = []
                if case .blocked(let reason, let attempts) = outcome {
                    reasons = [reason] + attempts.compactMap { $0.grounding?.blockingIssues.map(\.description).joined(separator: "; ") }
                }
                evidence.steps.append(StepEvidence(
                    stepIndex: stepNumber, stepDescription: nl, outcome: .blocked,
                    generationID: genEvidence.generationID, resultKind: genEvidence.resultKind, attemptCount: genEvidence.attemptCount,
                    preSnapshotID: pre.snapshotID, postSnapshotID: nil, groundingBlockingReasons: reasons, verified: nil, verificationReason: nil))
                appendNotExecuted(&evidence, from: stepNumber + 1, total: stepNLTexts.count, texts: stepNLTexts)
                return evidence // Part M/N: no downstream step is ever attempted once one blocks.
            }

            let validation = TestIRValidator.validate(ir)
            let records: [IRTestRunner.SegmentRecord]
            let branchEvidences: [BranchEvidence]
            do {
                // `testKey` here becomes the compiled SafeScenario's own id, which TrustedActionValidator
                // looks up in the controller's catalog — that catalog holds ONE placeholder scenario for
                // the whole run (see `rig`), so every step's compiled scenario must share the SAME id
                // (`scenarioID`), never the per-step `stepKey` (a real bug found in Live-execution contract, reconfirmed
                // in Stateful-scenario contract).
                (records, branchEvidences) = try await driveSteps(
                    ir.steps, verdicts: validation.stepVerdicts, testKey: scenarioID, title: "Stateful-scenario contract/48/49 step \(stepNumber)",
                    driver: driver, registry: registry, controller: controller, bundleID: bundleID)
            } catch {
                evidence.steps.append(StepEvidence(
                    stepIndex: stepNumber, stepDescription: nl, outcome: .blocked,
                    generationID: genEvidence.generationID, resultKind: genEvidence.resultKind, attemptCount: genEvidence.attemptCount,
                    preSnapshotID: pre.snapshotID, postSnapshotID: nil, groundingBlockingReasons: ["dispatch/branch threw: \(error)"], verified: nil, verificationReason: nil))
                appendNotExecuted(&evidence, from: stepNumber + 1, total: stepNLTexts.count, texts: stepNLTexts)
                return evidence
            }

            let post = try await driver.captureObservation(bundleID: bundleID)
            let allVerified = records.allSatisfy { if case .step(_, let verified, _) = $0 { return verified }; return true }
            let firstReason = records.compactMap { if case .step(_, let verified, let reason) = $0, !verified { return reason }; return nil }.first

            var stepEv = StepEvidence(
                stepIndex: stepNumber, stepDescription: nl, outcome: allVerified ? .completed : .blocked,
                generationID: genEvidence.generationID, resultKind: genEvidence.resultKind, attemptCount: genEvidence.attemptCount,
                preSnapshotID: pre.snapshotID, postSnapshotID: post.snapshotID, groundingBlockingReasons: [],
                verified: allVerified, verificationReason: firstReason)
            stepEv.branches = branchEvidences
            evidence.steps.append(stepEv)

            if !allVerified {
                appendNotExecuted(&evidence, from: stepNumber + 1, total: stepNLTexts.count, texts: stepNLTexts)
                return evidence // an unverified action makes the next "fresh observation" reflect an unknown state.
            }
        }

        return evidence
    }

    private static func appendNotExecuted(_ evidence: inout ScenarioEvidence, from startStep: Int, total: Int, texts: [String]) {
        guard startStep <= total else { return }
        for stepNumber in startStep...total {
            evidence.steps.append(StepEvidence(
                stepIndex: stepNumber, stepDescription: texts[stepNumber - 1], outcome: .notExecuted,
                generationID: nil, resultKind: nil, attemptCount: nil,
                preSnapshotID: nil, postSnapshotID: nil, groundingBlockingReasons: [], verified: nil, verificationReason: nil))
        }
    }
}
