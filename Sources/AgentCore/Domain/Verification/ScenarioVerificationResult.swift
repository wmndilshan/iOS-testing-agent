import Foundation

/// Trusted outcome of evaluating a scenario step's post-execution condition against a fresh UI observation.
public struct ScenarioVerificationResult: Codable, Sendable, Equatable {
    public let verified: Bool
    public let reason: String

    public init(
        verified: Bool,
        reason: String
    ) {
        self.verified = verified
        self.reason = reason
    }
}
