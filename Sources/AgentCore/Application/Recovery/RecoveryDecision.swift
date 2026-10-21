import Foundation

public struct RecoveryAttemptRecord: Codable, Sendable, Equatable {
    public let index: Int
    public let failureClass: FailureClass
    public let strategy: RecoveryStrategy?
    /// "ISSUED", "ESCALATED" or "FAILED_CLOSED".
    public let outcome: String
    public let detail: String
    public let timestamp: Date
}

public struct RecoveryDecision: Sendable, Equatable {
    public let failureClass: FailureClass
    public let strategy: RecoveryStrategy?
    public let action: RecoveryAction
    public let attemptNumber: Int
    public let explanation: String
}
