import Foundation

/// Trusted, deterministic taxonomy of everything that can go wrong in a closed-loop run.
///
/// Classification is performed by `FailureClassifier` from typed errors and known driver/tool
/// message shapes only. It never consults an LLM: a security-relevant category must not be
/// something a model can argue its way out of.
public enum FailureClass: String, Codable, Sendable, CaseIterable {
    case observationFailed       = "OBSERVATION_FAILED"
    case elementNotFound         = "ELEMENT_NOT_FOUND"
    case ambiguousTarget         = "AMBIGUOUS_TARGET"
    case staleSnapshot           = "STALE_SNAPSHOT"
    case validationFailed        = "VALIDATION_FAILED"
    case appStateMismatch        = "APP_STATE_MISMATCH"
    case xctestFailed            = "XCTEST_FAILED"
    case verificationFailed      = "VERIFICATION_FAILED"
    case appCrashed              = "APP_CRASHED"
    case simulatorUnavailable    = "SIMULATOR_UNAVAILABLE"
    case appLaunchFailed         = "APP_LAUNCH_FAILED"
    case appNotResponding        = "APP_NOT_RESPONDING"
    case approvalExpired         = "APPROVAL_EXPIRED"
    case approvalDenied          = "APPROVAL_DENIED"
    case recoveryBudgetExhausted = "RECOVERY_BUDGET_EXHAUSTED"
    case llmUnavailable          = "LLM_UNAVAILABLE"
    case llmBudgetExhausted      = "LLM_BUDGET_EXHAUSTED"
    case unknown                 = "UNKNOWN"

    /// Failures for which retrying the *same* mutating action can never be the right response,
    /// because a human explicitly said no or a hard safety limit was hit.
    public var isTerminalByPolicy: Bool {
        switch self {
        case .approvalDenied, .recoveryBudgetExhausted, .llmBudgetExhausted:
            return true
        default:
            return false
        }
    }
}

// MARK: - FailureClassifier
