import Foundation

/// Deterministic classification of every way an LLM exchange can fail.
///
/// The consequence of every kind here is confined to *obtaining a proposal*. None of them can
/// authorize, retry, or trigger a mutating XCTest action: a later, freshly obtained proposal must
/// still traverse the entire trusted pipeline.
/// Adopted by errors raised by a provider adapter or its transport, so classification stays
/// provider-neutral in the application layer.
public protocol LLMFailureClassifiable: Error {
    var llmFailureKind: LLMFailureKind { get }
}

public enum LLMFailureKind: String, Codable, Sendable, CaseIterable {
    case rateLimited = "HTTP_429"
    case serverError = "HTTP_5XX"
    case timeout = "TIMEOUT"
    case connectionFailure = "CONNECTION_FAILURE"
    case authentication = "AUTHENTICATION"
    case badRequest = "BAD_REQUEST"
    case invalidJSON = "INVALID_JSON"
    case schemaViolation = "SCHEMA_VIOLATION"
    case emptyResponse = "EMPTY_RESPONSE"
    case malformedProposal = "MALFORMED_PROPOSAL"
    case unknown = "UNKNOWN"

    public static func classify(_ error: Error) -> LLMFailureKind {
        // Provider/transport errors classify themselves (see `LLMFailureClassifiable`, adopted by
        // the adapters under Infrastructure/LLM), so this policy names no provider.
        if let e = error as? any LLMFailureClassifiable { return e.llmFailureKind }
        return .unknown
    }
}
