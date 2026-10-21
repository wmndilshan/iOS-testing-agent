import Foundation

public struct RecoveryPolicy: Codable, Sendable, Equatable {
    public let maxHealingAttempts: Int
    public let maxRecoverySteps: Int
    public let maxConsecutiveFailures: Int
    public let maxNoProgressSteps: Int

    public init(
        maxHealingAttempts: Int = 2,
        maxRecoverySteps: Int = 3,
        maxConsecutiveFailures: Int = 3,
        maxNoProgressSteps: Int = 2
    ) {
        self.maxHealingAttempts = maxHealingAttempts
        self.maxRecoverySteps = maxRecoverySteps
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.maxNoProgressSteps = maxNoProgressSteps
    }
}

// MARK: - RecoveryBudgetTracker
