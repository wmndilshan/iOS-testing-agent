import Foundation

/// Trusted Swift execution limits preventing unbounded loops or runaway actions.
/// The untrusted LLM has zero authority to modify these values.
public struct AgentRunLimits: Codable, Sendable, Equatable {
    public let maxSteps: Int
    public let maxObservations: Int
    public let maxConsecutiveFailures: Int
    public let maxNoProgressSteps: Int

    public init(
        maxSteps: Int = 10,
        maxObservations: Int = 20,
        maxConsecutiveFailures: Int = 3,
        maxNoProgressSteps: Int = 3
    ) {
        self.maxSteps = maxSteps
        self.maxObservations = maxObservations
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.maxNoProgressSteps = maxNoProgressSteps
    }
}

// MARK: - Deterministic Scenario Step Verification
