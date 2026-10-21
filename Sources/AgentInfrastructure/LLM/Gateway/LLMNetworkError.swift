import Foundation
import AgentCore

public enum LLMNetworkError: Error, LocalizedError, Sendable, Equatable {
    case badRequest(statusCode: Int, message: String)
    case unauthorized(statusCode: Int, message: String)
    case forbidden(statusCode: Int, message: String)
    case notFound(statusCode: Int, message: String)
    case rateLimited(statusCode: Int, retryAfter: TimeInterval?, message: String)
    case serverError(statusCode: Int, message: String)
    case timeout(String)
    case connectionFailure(String)
    case other(statusCode: Int, message: String)

    public var isRetryable: Bool {
        switch self {
        case .badRequest, .unauthorized, .forbidden, .notFound:
            return false
        case .rateLimited, .serverError, .timeout, .connectionFailure:
            return true
        case .other(let statusCode, _):
            return statusCode >= 500
        }
    }

    public var errorDescription: String? {
        switch self {
        case .badRequest(let code, let msg):
            return "Bad Request (HTTP \(code)): \(msg)"
        case .unauthorized(let code, let msg):
            return "Authentication failure (HTTP \(code)). Check API key: \(msg)"
        case .forbidden(let code, let msg):
            return "Forbidden access (HTTP \(code)): \(msg)"
        case .notFound(let code, let msg):
            return "Endpoint not found (HTTP \(code)): \(msg)"
        case .rateLimited(let code, let delay, let msg):
            let delayMsg = delay != nil ? " (Retry-After: \(delay!)s)" : ""
            return "Rate limited (HTTP \(code))\(delayMsg): \(msg)"
        case .serverError(let code, let msg):
            return "Temporary server failure (HTTP \(code)): \(msg)"
        case .timeout(let msg):
            return "Network request timed out: \(msg)"
        case .connectionFailure(let msg):
            return "Network connection failed: \(msg)"
        case .other(let code, let msg):
            return "HTTP error (\(code)): \(msg)"
        }
    }
}

// MARK: - BackoffPolicy
