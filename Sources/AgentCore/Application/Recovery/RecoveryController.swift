import Foundation

/// Classifies-and-decides component of the recovery pipeline:
///
///     Execution failure -> Classify -> Select strategy -> Emit recovery *proposal/instruction*
///     -> (caller) fresh observation -> re-evaluate -> retry ONLY through the trusted spine.
///
/// Security Invariant: this type has no dependency on `ToolRegistry`, any driver, or approval
/// state, so recovery is structurally incapable of executing a tool or authorizing anything.
/// Every attempt is recorded, and budgets plus loop detection fail closed instead of retrying.
public struct RecoveryController: Sendable {

    public private(set) var history: [RecoveryAttemptRecord] = []
    /// Maximum times the same (failure, strategy) pair may be issued before failing closed.
    public let maxRepeatsPerPair: Int

    public init(maxRepeatsPerPair: Int = 2) {
        self.maxRepeatsPerPair = maxRepeatsPerPair
    }

    public mutating func reset() {
        history.removeAll()
    }

    /// Ordered strategy ladder for a failure class. Earlier entries are cheaper/safer.
    public static func strategyLadder(for failure: FailureClass) -> [RecoveryStrategy] {
        switch failure {
        case .observationFailed, .staleSnapshot, .appNotResponding, .appStateMismatch:
            return [.freshObservation, .requestNewLLMProposal]
        case .elementNotFound:
            return [.freshObservation, .requestNewLLMProposal]
        case .validationFailed, .approvalExpired:
            return [.requestNewLLMProposal]
        case .xctestFailed:
            return [.freshObservation, .requestNewLLMProposal]
        case .verificationFailed:
            return [.freshObservation, .restorePreviousState]
        case .appCrashed, .appLaunchFailed:
            return [.restorePreviousState]
        case .ambiguousTarget, .simulatorUnavailable, .llmUnavailable, .unknown:
            return []
        case .approvalDenied, .recoveryBudgetExhausted, .llmBudgetExhausted:
            return []
        }
    }

    /// Decides the next recovery step. `budget` is the run's shared `RecoveryBudgetTracker`.
    public mutating func decide(
        _ context: RecoveryContext,
        budget: inout RecoveryBudgetTracker,
        now: Date = Date()
    ) -> RecoveryDecision {
        let failure = context.failure
        let attemptNumber = history.count + 1

        func finish(
            _ strategy: RecoveryStrategy?,
            _ action: RecoveryAction,
            outcome: String,
            _ explanation: String
        ) -> RecoveryDecision {
            history.append(RecoveryAttemptRecord(
                index: attemptNumber, failureClass: failure, strategy: strategy,
                outcome: outcome, detail: SecretRedactor.redact(explanation), timestamp: now
            ))
            return RecoveryDecision(
                failureClass: failure, strategy: strategy, action: action,
                attemptNumber: attemptNumber, explanation: SecretRedactor.redact(explanation)
            )
        }

        // 1. Terminal-by-policy failures and exhausted budgets never retry.
        if failure.isTerminalByPolicy {
            return finish(nil, .failClosed(reason: "\(failure.rawValue): terminal by policy."), outcome: "FAILED_CLOSED",
                          "\(failure.rawValue) is terminal by policy; no automated recovery.")
        }
        let (exhausted, exhaustedReason) = budget.isExhausted
        if exhausted {
            let reason = exhaustedReason ?? "Recovery budget exhausted."
            return finish(nil, .failClosed(reason: "\(FailureClass.recoveryBudgetExhausted.rawValue): \(reason)"),
                          outcome: "FAILED_CLOSED", reason)
        }

        // 2. A failure with no safe automated strategy goes straight to a person.
        let ladder = Self.strategyLadder(for: failure)

        if ladder.isEmpty {
            let (reason, guidance) = Self.escalationText(for: failure)
            return finish(nil, .humanIntervention(reason: reason, guidance: guidance),
                          outcome: "ESCALATED", reason)
        }

        // 3. Select the first ladder rung not yet spent for this failure class.
        for strategy in ladder {
            // Any prior record (issued, escalated or failed) for this pair counts against it.
            let timesTried = history.filter { $0.failureClass == failure && $0.strategy == strategy }.count
            let allowed = strategy == .requestNewLLMProposal ? maxRepeatsPerPair : 1
            if timesTried >= allowed { continue }

            switch strategy {
            case .freshObservation:
                budget.recordRecoveryStep()
                return finish(.freshObservation,
                              .captureFreshObservation(reason: "\(failure.rawValue): re-observe before any retry."),
                              outcome: "ISSUED", "Capture a fresh read-only observation and re-evaluate.")

            case .requestNewLLMProposal:
                if context.proposalWasAlreadyRejected {
                    return finish(nil, .failClosed(reason: "Model repeated a proposal that was already rejected; not asking again."),
                                  outcome: "FAILED_CLOSED", "Refusing to re-ask for the same invalid action.")
                }
                budget.recordRecoveryStep()
                return finish(.requestNewLLMProposal,
                              .requestNewProposal(reason: "\(failure.rawValue): obtain a fresh proposal.", allowLLM: context.llmBudgetAvailable),
                              outcome: "ISSUED", "Obtain a new proposal from the model if its budget allows; it must pass the full trusted pipeline.")

            case .reOpenParentScreen, .restorePreviousState:
                // Restoring UI state requires mutating the app. That can only ever happen as a
                // normally proposed, validated and human-approved step — never as hidden recovery
                // execution — so it is surfaced to the operator instead of being auto-dispatched.
                return finish(strategy,
                              .humanIntervention(reason: "\(failure.rawValue): state restoration required.",
                                                 guidance: strategy == .reOpenParentScreen
                                                    ? "Reopen the parent screen, then capture a fresh observation and re-authorize."
                                                    : "Restore the previous UI state (e.g. dismiss the modal or relaunch the app), then capture a fresh observation and re-authorize."),
                              outcome: "ESCALATED", "Automatic state restoration is not performed; operator action plus new authorization required.")
            }
        }

        // 4. Ladder exhausted for this failure.
        return finish(nil, .failClosed(reason: "\(failure.rawValue): all recovery strategies exhausted."),
                      outcome: "FAILED_CLOSED", "All strategies for \(failure.rawValue) were tried; failing closed.")
    }

    private static func escalationText(for failure: FailureClass) -> (String, String) {
        switch failure {
        case .ambiguousTarget:
            return ("AMBIGUOUS_TARGET: refusing to guess.", "Several elements match; a human must select the intended target. The agent will not guess or re-ask the model for the same action.")
        case .simulatorUnavailable:
            return ("SIMULATOR_UNAVAILABLE: environment fault.", "Boot or repair the simulator, then start a new run; nothing was executed against an unavailable device.")
        case .llmUnavailable:
            return ("LLM_UNAVAILABLE: no proposal could be obtained.", "Check network and API key, then retry. No action was executed as a result of the failure.")
        default:
            return ("\(failure.rawValue): unclassified failure.", "Inspect the run trace; automated recovery has no safe strategy for this failure.")
        }
    }
}
