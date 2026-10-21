import Foundation

/// Recovery strategies are a closed enum, deliberately not a protocol hierarchy.
///
/// The cases share one ladder table (`RecoveryController.strategyLadder`), one budget and one decision
/// function. `reOpenParentScreen` and `restorePreviousState` are guidance-only escalations. Turning them
/// into types would add files and a registry without independent dependencies, policies or tests, and
/// would spread the one place that decides what recovery may do.
///
/// Strategies are advisory: they produce a `RecoveryDecision`; only the trusted controller acts on it,
/// and any resulting action is a normal proposal.
public enum RecoveryStrategy: String, Codable, Sendable, CaseIterable {
    case freshObservation      = "fresh_observation"
    case reOpenParentScreen    = "reopen_parent_screen"
    case restorePreviousState  = "restore_previous_state"
    case requestNewLLMProposal = "request_new_llm_proposal"
}
