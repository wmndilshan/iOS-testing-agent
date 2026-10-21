import Foundation
import AgentCore

/// Minimal `LLMClientProtocol` conformance for DeepSeek's OpenAI-compatible chat completions API
/// (`POST https://api.deepseek.com/chat/completions`). Application-layer consumers depend only on
/// the `LLMClientProtocol` port, never on a concrete provider.
/// Deliberately simple: a single non-streaming request via `URLSession.shared`, with none of
/// `LLMGateway`'s retry/backoff machinery.
public struct DeepSeekClient: LLMClientProtocol, Sendable {
    public enum DeepSeekError: Error, Sendable {
        case httpError(statusCode: Int, message: String)
        case malformedResponse(String)
    }

    public let apiKey: String
    public let model: String
    public let maxTokens: Int
    private let session: URLSession

    /// `maxTokens` defaults to `deepseek-chat`'s documented maximum (8192). A very verbose TestIR document
    /// (e.g. DEMO-TC-872's full 32 AIO steps expanded with explicit verification/signal detail) can still
    /// exceed that ceiling and truncate mid-object; `deepseek-reasoner` accepts a much larger completion
    /// budget, so a caller selecting that model should pass a correspondingly larger `maxTokens`.
    /// How long one request may take. A planner call that hangs is cut off and retried instead of blocking the run for minutes.
    private let requestTimeout: TimeInterval

    public init(apiKey: String, model: String = "deepseek-chat", maxTokens: Int = 8192, session: URLSession = .shared, requestTimeout: TimeInterval = 550) {
        self.requestTimeout = requestTimeout
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.session = session
    }

    public func sendPrompt(_ prompt: String) async throws -> String {
        try await complete(LLMRequest(messages: [LLMMessage(role: .user, text: prompt)], temperature: 0.2))
    }

    /// Maps a provider-neutral request onto DeepSeek's OpenAI-style chat body:
    /// system instruction, then each user message and each model message (`assistant`).
    public func complete(_ llmRequest: LLMRequest) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        // URLSession's default 60s request timeout is too short for `deepseek-reasoner` generating a large
        // completion (it reasons at length before emitting the final JSON); this is a manual smoke-test
        // entry point, not a hot path, so a generous fixed timeout is appropriate.
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var messages: [[String: String]] = []
        if let system = llmRequest.systemInstruction?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for message in llmRequest.messages {
            let role = message.role == .model ? "assistant" : "user"
            messages.append(["role": role, "content": message.text])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": llmRequest.temperature ?? 0.2,
            "max_tokens": maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.malformedResponse("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekError.httpError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DeepSeekError.malformedResponse(String(data: data, encoding: .utf8) ?? "<undecodable body>")
        }
        return content
    }
}
