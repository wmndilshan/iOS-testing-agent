import Foundation

/// Deterministically tracks recovery loops and enforces policy limits.
/// Prevents infinite self-healing loops.
public struct RecoveryBudgetTracker: Sendable {
    public let policy: RecoveryPolicy
    public private(set) var healingAttempts: Int = 0
    public private(set) var recoverySteps: Int = 0
    public private(set) var consecutiveFailures: Int = 0
    public private(set) var consecutiveNoProgressSteps: Int = 0

    public init(policy: RecoveryPolicy = RecoveryPolicy()) {
        self.policy = policy
    }

    public mutating func recordHealingAttempt() {
        healingAttempts += 1
    }

    public mutating func recordRecoveryStep() {
        recoverySteps += 1
    }

    public mutating func recordFailure() {
        consecutiveFailures += 1
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        consecutiveNoProgressSteps = 0
    }

    public mutating func recordProgress() {
        consecutiveNoProgressSteps = 0
    }

    public mutating func recordNoProgress() {
        consecutiveNoProgressSteps += 1
    }

    /// Evaluates if the recovery budget is exhausted.
    public var isExhausted: (exhausted: Bool, reason: String?) {
        if healingAttempts > policy.maxHealingAttempts {
            return (true, "Healing budget exhausted: \(healingAttempts) attempts exceeded limit of \(policy.maxHealingAttempts).")
        }
        if recoverySteps > policy.maxRecoverySteps {
            return (true, "Recovery budget exhausted: \(recoverySteps) steps exceeded limit of \(policy.maxRecoverySteps).")
        }
        if consecutiveFailures >= policy.maxConsecutiveFailures {
            return (true, "Consecutive failure limit reached: \(consecutiveFailures) failures exceeded limit of \(policy.maxConsecutiveFailures).")
        }
        if consecutiveNoProgressSteps >= policy.maxNoProgressSteps {
            return (true, "No-progress limit reached: \(consecutiveNoProgressSteps) steps produced no state change (limit: \(policy.maxNoProgressSteps)).")
        }
        return (false, nil)
    }

    public mutating func reset() {
        healingAttempts = 0
        recoverySteps = 0
        consecutiveFailures = 0
        consecutiveNoProgressSteps = 0
    }
}
