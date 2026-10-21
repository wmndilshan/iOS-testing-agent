import Foundation
import AgentCore

enum LLMError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case emptyResponse
    case noCandidates(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Gemini API endpoint URL."
        case .httpError(let statusCode, let message):
            switch statusCode {
            case 401, 403:
                return "Authentication failed (HTTP \(statusCode)). Please check that your API key is valid."
            case 404:
                return "Model or resource not found (HTTP 404). Details: \(message)"
            case 429:
                return "Quota exceeded / Rate limited (HTTP 429). Details: \(message)"
            default:
                return "Gemini HTTP error (\(statusCode)): \(message)"
            }
        case .decodingError(let details):
            return "Failed to decode Gemini response: \(details)"
        case .emptyResponse:
            return "Empty response received from Gemini API."
        case .noCandidates(let reason):
            return "No candidates returned by Gemini: \(reason)"
        case .networkError(let details):
            return "Network error: \(details)"
        }
    }
}
