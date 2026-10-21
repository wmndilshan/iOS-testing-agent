import Foundation
import AgentCore

extension LLMNetworkError: ErrorCategoryProviding {
    public var errorCategory: ErrorCategory {
        switch self {
        case .unauthorized, .forbidden: return .configuration
        case .timeout: return .timeout
        case .badRequest, .notFound: return .llm
        case .rateLimited, .serverError, .connectionFailure, .other: return .network
        }
    }
}

extension LLMError: ErrorCategoryProviding {
    public var errorCategory: ErrorCategory {
        switch self {
        case .httpError(let code, _): return code == 401 || code == 403 ? .configuration : .network
        case .networkError(let message): return message.lowercased().contains("timed out") ? .timeout : .network
        case .emptyResponse, .noCandidates: return .llm
        case .decodingError: return .parsing
        case .invalidURL: return .configuration
        }
    }
}

extension Configuration.ConfigError: ErrorCategoryProviding {
    public var errorCategory: ErrorCategory { .configuration }
}
