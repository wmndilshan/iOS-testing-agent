import Foundation
import AgentCore

public final class LLMClient: LLMClientProtocol, Sendable {
    public let config: Configuration
    public let gateway: LLMGateway
    /// Logs semantic LLM events (`llm.request.*`). Transport events belong to `LLMGateway`.
    public let logger: any AppLogger
    private let session: URLSession

    public init(
        config: Configuration,
        session: URLSession = .shared,
        gateway: LLMGateway? = nil,
        clock: ClockProtocol = SystemClock(),
        logger: any AppLogger = NullLogger()
    ) {
        self.config = config
        self.logger = logger
        self.session = session
        self.gateway = gateway ?? LLMGateway(
            transport: URLSessionTransport(session: session),
            clock: clock,
            logger: logger,
            provider: "gemini"
        )
    }

    /// Sends one user message. The structured path is `complete`.
    public func sendPrompt(_ prompt: String) async throws -> String {
        try await complete(LLMRequest(messages: [LLMMessage(role: .user, text: prompt)]))
    }

    /// Sends the system instruction, user messages, and model messages as one Gemini request.
    public func complete(_ request: LLMRequest) async throws -> String {
        let started = Date()
        let promptChars = request.messages.reduce(0) { $0 + $1.text.count }
        logger.info(.llm, "llm.request.started", fields: [
            "provider": "gemini", "model": .string(config.model),
            "messageCount": .int(request.messages.count),
            "userMessageCount": .int(request.messages.filter { $0.role == .user }.count),
            "modelMessageCount": .int(request.messages.filter { $0.role == .model }.count),
            "hasSystemInstruction": .bool(!(request.systemInstruction ?? "").isEmpty),
            "promptChars": .int(promptChars),
        ])
        do {
            let candidate = try await generateContent(request: request)
            guard let text = candidate.text else {
                throw LLMError.noCandidates("Response contained no text content.")
            }
            logger.info(.llm, "llm.request.completed", fields: [
                "provider": "gemini", "responseChars": .int(text.count),
            ], duration: Date().timeIntervalSince(started))
            return text
        } catch {
            logger.error(.llm, "llm.request.failed", fields: ["provider": "gemini"],
                         duration: Date().timeIntervalSince(started), errorClass: LLMFailureKind.classify(error).rawValue)
            throw error
        }
    }

    /// Primary generateContent call. The body is the mapped `LLMRequest`, including system instruction.
    func generateContent(request llmRequest: LLMRequest) async throws -> Candidate {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent"
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let requestBody = llmRequest.geminiGenerateContentRequest
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw LLMError.decodingError("Failed to encode request: \(error.localizedDescription)")
        }

        let data: Data
        do {
            data = try await gateway.execute(request: request)
        } catch let netErr as LLMNetworkError {
            switch netErr {
            case .badRequest(let code, let msg), .unauthorized(let code, let msg), .forbidden(let code, let msg), .notFound(let code, let msg):
                throw LLMError.httpError(statusCode: code, message: msg)
            case .rateLimited(let code, _, let msg):
                throw LLMError.httpError(statusCode: code, message: msg)
            case .serverError(let code, let msg), .other(let code, let msg):
                throw LLMError.httpError(statusCode: code, message: msg)
            case .timeout(let msg):
                throw LLMError.networkError("Request timed out: \(msg)")
            case .connectionFailure(let msg):
                throw LLMError.networkError("Connection failed: \(msg)")
            }
        }

        let decoded: GenerateContentResponse
        do {
            decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        } catch {
            throw LLMError.decodingError(error.localizedDescription)
        }

        if let apiError = decoded.error {
            throw LLMError.httpError(statusCode: apiError.code ?? 500, message: apiError.message ?? "Unknown API error")
        }

        guard let firstCandidate = decoded.candidates?.first else {
            throw LLMError.noCandidates("Zero candidates in Gemini API response.")
        }

        return firstCandidate
    }
}
