import Foundation
import AgentCore
import AgentInfrastructure

/// Answers the first requests with the fast model and later ones with the strong model. One instance serves one planning attempt: the first
/// tries are cheap, and only when the plan keeps being rejected (it named something not on screen, or did not validate) does the strong model,
/// which takes ten times as long, get involved.
final class EscalatingLLMClient: LLMClientProtocol, @unchecked Sendable {
    private let fast: any LLMClientProtocol
    private let strong: any LLMClientProtocol
    private let lock = NSLock()
    private var calls = 0
    /// The request number (from 0) at which the strong model takes over.
    private let strongFrom: Int

    init(fast: any LLMClientProtocol, strong: any LLMClientProtocol, strongFrom: Int = 1) {
        self.fast = fast
        self.strong = strong
        self.strongFrom = strongFrom
    }

    private func next() -> any LLMClientProtocol {
        lock.withLock {
            defer { calls += 1 }
            return calls < strongFrom ? fast : strong
        }
    }

    func complete(_ request: LLMRequest) async throws -> String { try await next().complete(request) }
    func sendPrompt(_ prompt: String) async throws -> String { try await next().sendPrompt(prompt) }
}
