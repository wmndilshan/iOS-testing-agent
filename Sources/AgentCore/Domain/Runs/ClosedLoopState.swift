import Foundation

/// Deterministic state machine governing the closed-loop lifecycle:
/// Observe -> Propose -> Validate -> Await Approval -> Execute -> Fresh Observe -> Verify -> Complete/Fail/Block
public enum ClosedLoopState: String, Codable, Sendable, CaseIterable {
    case idle = "Idle"
    case observing = "Observing"
    case proposing = "Proposing"
    case validating = "Validating"
    case awaitingApproval = "Awaiting Approval"
    case executing = "Executing"
    case postObserving = "Post Observing"
    case verifying = "Verifying"
    case advancing = "Advancing"
    case completed = "Completed"
    case failed = "Failed"
    case blocked = "Blocked"
    case cancelled = "Cancelled"

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .blocked || self == .cancelled
    }
}

// MARK: - Trusted Run Limits
