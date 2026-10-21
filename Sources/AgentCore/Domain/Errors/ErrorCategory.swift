import Foundation

/// Neutral, provider-independent classification of why something failed.
///
/// Infrastructure errors (an XCTest failure, an HTTP status, a decoding error) map onto this small set so
/// application logic, logs, traces and the UI never depend on a vendor's error type. Error *messages*
/// are not part of the classification and are redacted before they leave the process.
public enum ErrorCategory: String, Sendable, Codable, CaseIterable {
    case validation, authorization, approval, observation
    case targetNotFound, targetNotHittable, toolUnavailable
    case execution, xctest, simulator
    case network, llm, parsing
    case verification, timeout, persistence, security, configuration

}

/// Adopted by error types so they classify themselves.
public protocol ErrorCategoryProviding: Error {
    var errorCategory: ErrorCategory { get }
}

extension ErrorCategory {
    /// The category of any error; `execution` when the error does not classify itself.
    public static func of(_ error: Error) -> ErrorCategory {
        (error as? any ErrorCategoryProviding)?.errorCategory ?? .execution
    }
}
