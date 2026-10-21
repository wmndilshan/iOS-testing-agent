import Foundation

/// Why a model's proposal was not admitted to the trusted pipeline.
public enum LLMProposalPipelineError: Error, LocalizedError, Sendable, Equatable {
    case validationFailed(reason: String)
    case duplicateProposal(reason: String)

    public var errorDescription: String? {
        switch self {
        case .validationFailed(let reason): return "Trusted validation failed: \(reason)"
        case .duplicateProposal(let reason): return "Proposal rejected as duplicate: \(reason)"
        }
    }
}
