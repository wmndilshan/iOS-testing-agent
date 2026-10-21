import Foundation
import AgentCore

/// Maps transport and Gemini-client errors onto the provider-neutral `LLMFailureKind`.
extension LLMNetworkError: LLMFailureClassifiable {
    public var llmFailureKind: LLMFailureKind {
        switch self {
        case .rateLimited: return .rateLimited
        case .serverError: return .serverError
        case .timeout: return .timeout
        case .connectionFailure: return .connectionFailure
        case .unauthorized, .forbidden: return .authentication
        case .badRequest, .notFound: return .badRequest
        case .other(let code, _): return code >= 500 ? .serverError : .unknown
        }
    }
}

extension LLMError: LLMFailureClassifiable {
    public var llmFailureKind: LLMFailureKind {
        switch self {
        case .httpError(let code, _):
            if code == 429 { return .rateLimited }
            if code >= 500 { return .serverError }
            if code == 401 || code == 403 { return .authentication }
            return .badRequest
        case .networkError(let msg):
            return msg.lowercased().contains("timed out") ? .timeout : .connectionFailure
        case .emptyResponse, .noCandidates: return .emptyResponse
        case .decodingError: return .invalidJSON
        case .invalidURL: return .badRequest
        }
    }
}
