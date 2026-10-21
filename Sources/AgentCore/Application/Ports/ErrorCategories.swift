import Foundation

// Deliberate, exhaustive mappings of the application's error types onto `ErrorCategory`.
// A new error case must be classified here (the switches are exhaustive), so nothing silently falls back.

extension DriverError: ErrorCategoryProviding {
    public var errorCategory: ErrorCategory {
        switch self {
        case .staleSnapshot: return .observation
        case .elementNotFound, .ambiguousElement: return .targetNotFound
        case .elementNotHittable, .elementDisabled: return .targetNotHittable
        case .typeMismatch: return .validation
        case .actionFailed: return .xctest
        case .simulatorNotAvailable: return .simulator
        case .observationFailed: return .observation
        case .unsupportedCapability: return .toolUnavailable
        case .timedOut: return .timeout
        case .wrongApplication: return .observation
        }
    }
}

extension ToolRegistryError: ErrorCategoryProviding {
    public var errorCategory: ErrorCategory {
        switch self {
        case .toolNotFound: return .toolUnavailable
        case .invalidArguments: return .validation
        case .authorizationRequired, .authorizationMismatch: return .authorization
        }
    }
}

extension LLMProposalPipelineError: ErrorCategoryProviding {
    public var errorCategory: ErrorCategory {
        switch self {
        case .validationFailed, .duplicateProposal: return .validation
        }
    }
}

extension ActionFailureKind {
    /// The one mapping from application/infrastructure errors onto the action-failure taxonomy.
    public static func of(_ error: Error) -> ActionFailureKind {
        switch error {
        case let e as DriverError:
            switch e {
            case .staleSnapshot: return .staleSnapshot
            case .elementNotFound, .ambiguousElement, .typeMismatch: return .targetNotFound
            case .elementNotHittable: return .targetNotHittable
            case .elementDisabled: return .targetDisabled
            case .actionFailed: return .xctestFailure
            case .simulatorNotAvailable: return .simulatorFailure
            case .observationFailed: return .observationFailed
            case .unsupportedCapability: return .unsupportedCapability
            case .timedOut: return .timeout
            case .wrongApplication: return .observationFailed
            }
        case let e as ToolRegistryError:
            switch e {
            case .toolNotFound: return .unsupportedCapability
            case .invalidArguments: return .invalidArguments
            case .authorizationRequired, .authorizationMismatch: return .authorizationFailed
            }
        case is CancellationError: return .cancelled
        case is ArtifactStoreError: return .driverFailure
        default: return .driverFailure
        }
    }
}
