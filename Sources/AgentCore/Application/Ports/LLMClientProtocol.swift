import Foundation

public protocol LLMClientProtocol: Sendable {
    /// One turn. `request` carries the system instruction and the user and model messages. The returned string is untrusted model text.
    func complete(_ request: LLMRequest) async throws -> String

    /// Convenient single-shot text prompt helper. Equivalent to `complete` with one user message.
    func sendPrompt(_ prompt: String) async throws -> String
}
