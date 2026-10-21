import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

final class SequentialMockLLMClient: LLMClientProtocol, @unchecked Sendable {
    var queuedResponses: [Result<String, Error>] = []
    private(set) var callCount: Int = 0
    private(set) var recordedPrompts: [String] = []

    init(queuedResponses: [Result<String, Error>] = []) {
        self.queuedResponses = queuedResponses
    }

    func complete(_ request: LLMRequest) async throws -> String {
        try await sendPrompt(request.messages.map(\.text).joined(separator: "\n"))
    }

    func sendPrompt(_ prompt: String) async throws -> String {
        callCount += 1
        recordedPrompts.append(prompt)
        if queuedResponses.isEmpty {
            return "{}"
        }
        let next = queuedResponses.removeFirst()
        switch next {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - 1. Required Tests: Parsing (Section 20)
