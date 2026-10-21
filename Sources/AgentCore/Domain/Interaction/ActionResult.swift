import Foundation

/// The single, neutral taxonomy for why an interaction did not succeed. Infrastructure and application
/// errors map onto it (see `ActionFailureKind.of`); no layer defines its own action-failure enum.
public enum ActionFailureKind: String, Sendable, Codable, CaseIterable {
    case targetNotFound, targetNotHittable, targetDisabled, staleSnapshot
    case invalidArguments, unsupportedCapability
    case timeout, keyboardUnavailable, overlayNotFound, gestureFailed
    case driverFailure, simulatorFailure, xctestFailure
    case verificationFailed, authorizationFailed, observationFailed, noProgress, cancelled

    /// The broad category used by logs, traces and `ToolFailure`.
    public var category: ErrorCategory {
        switch self {
        case .targetNotFound, .overlayNotFound: return .targetNotFound
        case .targetNotHittable, .targetDisabled: return .targetNotHittable
        case .staleSnapshot, .observationFailed: return .observation
        case .invalidArguments: return .validation
        case .unsupportedCapability: return .toolUnavailable
        case .timeout, .noProgress: return .timeout
        case .keyboardUnavailable, .gestureFailed, .driverFailure: return .execution
        case .simulatorFailure: return .simulator
        case .xctestFailure: return .xctest
        case .verificationFailed: return .verification
        case .authorizationFailed: return .authorization
        case .cancelled: return .execution
        }
    }
}

public struct ActionFailure: Sendable, Codable, Equatable {
    public let kind: ActionFailureKind
    /// Redacted before it is stored or logged.
    public let message: String

    public init(kind: ActionFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// The standardized outcome of one iOS action. Never a bare string, never contains secrets or raw bytes:
/// large evidence is an `ArtifactReference`, and typed text is not recorded.
public struct IOSActionResult: Sendable, Codable, Equatable {
    public let executionID: String?
    public let toolName: String?
    public let actionType: String
    public let startedAt: Date
    public let finishedAt: Date
    public let success: Bool
    public let failure: ActionFailure?
    public let evidence: [ArtifactReference]
    /// The fresh observation this action produced or observed, when it produced one.
    public let postObservationID: String?
    /// Small, non-sensitive key/value facts (never typed text, credentials or raw payloads).
    public let diagnostics: [String: String]

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public init(executionID: String?, toolName: String?, actionType: String, startedAt: Date, finishedAt: Date,
                success: Bool, failure: ActionFailure? = nil, evidence: [ArtifactReference] = [],
                postObservationID: String? = nil, diagnostics: [String: String] = [:]) {
        self.executionID = executionID; self.toolName = toolName; self.actionType = actionType
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.success = success; self.failure = failure
        self.evidence = evidence; self.postObservationID = postObservationID; self.diagnostics = diagnostics
    }
}
