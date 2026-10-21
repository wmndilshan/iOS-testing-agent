import Foundation

/// What recovery wants to happen next. This type is deliberately *not* executable: every case is
/// either a request for a read-only observation, an `ActionProposal` that must enter the normal
/// trusted pipeline (`handleProposal` -> TrustedActionValidator -> approval -> token ->
/// `dispatchCurrentStep`), a request for a fresh proposal, or an escalation. There is no case that
/// names a tool, a driver call, or an approval.
public enum RecoveryAction: Sendable, Equatable {
    /// Capture a fresh, read-only observation and re-evaluate. Never mutates the app.
    case captureFreshObservation(reason: String)
    /// Obtain a new proposal from the model. It must pass the full pipeline.
    case requestNewProposal(reason: String, allowLLM: Bool)
    /// Automation stops; a human must act (e.g. relaunch the app, restore screen state, choose
    /// among ambiguous targets). After that, a fresh observation and new authorization are needed.
    case humanIntervention(reason: String, guidance: String)
    /// Fail closed: no further automated attempts.
    case failClosed(reason: String)

    public var isTerminal: Bool {
        switch self {
        case .failClosed, .humanIntervention: return true
        default: return false
        }
    }
}
