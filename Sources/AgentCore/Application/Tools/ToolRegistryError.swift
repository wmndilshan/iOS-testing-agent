import Foundation

public enum ToolRegistryError: Error, LocalizedError, Equatable {
    case toolNotFound(String)
    case invalidArguments(String)
    /// A mutating tool was requested without a `DispatchAuthorizer.Authorized` proof.
    case authorizationRequired(String)
    /// The proof does not cover this exact tool call (different tool or arguments).
    case authorizationMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool '\(name)' is not registered in the allowlisted tool registry."
        case .invalidArguments(let reason):
            return "Invalid arguments: \(reason)"
        case .authorizationRequired(let name):
            return "Tool '\(name)' can change the app and requires trusted authorization. Read-only execution refused."
        case .authorizationMismatch(let name):
            return "Authorization does not cover this call to '\(name)' (tool or arguments differ from what was approved)."
        }
    }
}
