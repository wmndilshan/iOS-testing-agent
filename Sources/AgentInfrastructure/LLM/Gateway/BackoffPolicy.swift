import Foundation
import AgentCore

public struct BackoffPolicy: Sendable, Equatable {
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let maxAttempts: Int
    public let jitter: Double?

    public init(
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 8.0,
        maxAttempts: Int = 4,
        jitter: Double? = nil
    ) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.jitter = jitter
    }

    /// Computes backoff delay for the given attempt index (1-indexed).
    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let ra = retryAfter, ra > 0 {
            return min(maxDelay, ra)
        }
        let exponent = Double(max(0, attempt - 1))
        let calculated = initialDelay * pow(2.0, exponent)
        let capped = min(maxDelay, calculated)
        if let j = jitter {
            return min(maxDelay, capped + j)
        }
        return capped
    }
}

// MARK: - LLMNetworkTransportProtocol
