import Foundation
import AgentCore
import AgentInfrastructure

extension CaseRunSession {
    /// Runs one validated TestIR document: linear segments through the trusted spine, branches and verify-only steps against fresh observations.
    @discardableResult
    func runDocument(ir: TestIR, rowPrefix: String, stepNumber: Int?, startStep: Int, humanNumbers: Set<Int>, tentative: Bool = false, evidence: Bool = true) async -> Bool {
        let validation = TestIRValidator.validate(ir)
        let all = Self.flatten(ir.steps)
        func number(_ step: IRStep) -> Int { stepNumber ?? step.sourceStepNumber }
        func rid(_ step: IRStep) -> String { rowPrefix + step.id }
        var anyFailed = false
        func row(_ step: IRStep, _ status: CaseRunReport.Status, _ detail: String, approval: String? = nil) {
            if status == .failed { anyFailed = true }
            // A tentative run (replaying a learned skill) never fails the test: a failure is reported as skipped and the caller plans instead.
            let recorded: CaseRunReport.Status = tentative && status == .failed ? .skipped : status
            recordRow(rid(step), number: number(step), intent: step.intent, action: step.action.rawValue, recorded, tentative && status == .failed ? "replay: \(detail)" : detail, approval: approval)
        }
        guard validation.isAccepted else {
            for reason in validation.rejectionReasons { print("  ! \(SecretRedactor.redact(reason))") }
            recordRow(rowPrefix + "ir", number: stepNumber ?? 0, intent: title, action: "validate", tentative ? .skipped : .failed, "TestIR rejected by the validator; nothing executed")
            return false
        }
        let verdicts = validation.stepVerdicts
        registerRows(all.map { (id: rid($0), number: number($0), intent: $0.intent, action: $0.action.rawValue) })
        let executor = TestIRExecutor(controller: controller)
        var remaining = ir.steps

        while !remaining.isEmpty, !aborted {
            switch TestIRExecutor.nextSegment(remaining) {
            case .done:
                remaining = []
            case .branch(let branch, let stepID, let rest):
                let branchStep = all.first { $0.id == stepID }
                guard let observation = await observe() else {
                    if let branchStep { row(branchStep, .failed, "observation failed before branch decision") }
                    remaining = rest
                    continue
                }
                switch executor.evaluateBranch(branch, freshObservation: observation) {
                case .selected(let arm, let snapshotID):
                    if let branchStep { row(branchStep, .passed, "branch decided: \(arm == .then ? "then" : "else") arm (snapshot \(snapshotID))") }
                    remaining = (arm == .then ? branch.thenSteps : branch.elseSteps) + rest
                case .indeterminate(let reason):
                    if let branchStep { row(branchStep, .failed, "branch indeterminate: \(reason)") }
                    print("✗ Execution halts: a branch is never guessed.")
                    abort()
                }
            case .linear(let segment, let rest):
                for step in segment {
                    if aborted { break }
                    if stepNumber == nil, step.sourceStepNumber < startStep { row(step, .skipped, "before --start-step=\(startStep)"); continue }
                    if stepNumber == nil, humanNumbers.contains(step.sourceStepNumber) {
                        if step.credentialRef != nil { await waitForHumanLogin() }
                        row(step, .humanCompleted, step.credentialRef != nil ? "password entered by the human" : "performed by the human as part of login")
                        continue
                    }
                    guard case .admitted = verdicts[step.id] else {
                        if case .unsupported(let reason)? = verdicts[step.id] { row(step, .unsupported, reason) } else { row(step, .unsupported, "not admitted by the validator") }
                        continue
                    }
                    markRunning(rid(step))
                    print("  > \(rid(step)): \(step.intent)")
                    guard let observation = await observe() else { row(step, .failed, "fresh observation failed; nothing dispatched"); continue }
                    if let reason = vacuousAbsenceReason(step) { row(step, .unsupported, reason); continue }
                    if step.action == .verifyOnly {
                        if let result = executor.evaluateVerifyOnly(step, freshObservation: observation) {
                            row(step, result.verified ? .passed : .failed, result.reason)
                        } else {
                            row(step, .unsupported, "verifyOnly step could not be evaluated")
                        }
                        if evidence { await captureEvidence(rowID: rid(step)) }
                        continue
                    }
                    guard let scenario = TestIRExecutor.compileLinearScenario(testKey: key, title: title, steps: [step], verdicts: verdicts, credentials: credentials),
                          controller.startScenario(scenario) else {
                        row(step, .unsupported, "step did not compile (for example a credential reference without a value)")
                        continue
                    }
                    switch executor.proposeCurrentStep(freshObservation: observation) {
                    case .pending(let request):
                        print("    proposal validated: tool=\(request.toolName ?? "?")")
                    case .noMatchingElement:
                        row(step, .failed, "target element not found in the live accessibility tree; nothing dispatched")
                        continue
                    case .rejected(let reason):
                        row(step, .failed, "proposal rejected by the trusted validator: \(reason)")
                        continue
                    case .noActiveStep:
                        row(step, .failed, "no active step")
                        continue
                    }
                    let approvedBy: String
                    switch approve(step, rowID: rid(step), observation: observation) {
                    case .granted(let source):
                        approvedBy = source
                    case .needsTerminal:
                        row(step, .failed, "this action looks destructive ('\(step.intent)') and needs a human approval; run it from a terminal, or pass --allow-destructive. Nothing was dispatched")
                        continue
                    case .notGranted:
                        row(step, .failed, "approval was not granted; nothing dispatched")
                        continue
                    }
                    switch await controller.dispatchCurrentStep(toolRegistry: registry, bundleID: bundleID, isLive: mode.isLive) {
                    case .success(let verification):
                        row(step, verification.verified ? .passed : .failed, verification.reason, approval: approvedBy)
                    case .failure(let error):
                        row(step, .failed, SecretRedactor.redact(error.localizedDescription), approval: approvedBy)
                    }
                    if evidence { await captureEvidence(rowID: rid(step)) }
                }
                remaining = rest
            }
        }
        return !anyFailed
    }

    /// Every step in document order, including both arms of each branch.
    private static func flatten(_ steps: [IRStep]) -> [IRStep] {
        steps.flatMap { step -> [IRStep] in
            guard let branch = step.branch else { return [step] }
            return [step] + flatten(branch.thenSteps) + flatten(branch.elseSteps)
        }
    }
}
