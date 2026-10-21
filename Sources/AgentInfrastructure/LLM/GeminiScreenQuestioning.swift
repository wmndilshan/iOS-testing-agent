import Foundation
import AgentCore

/// `ScreenQuestioning` over the Gemini client the screenshot judge already uses. Created only when a Gemini key is configured.
/// Fast, small models go first (measured: about 3 s against 7 to 35 s for the default model); a model that fails or is out of quota is set
/// aside for ten minutes and the next one answers.
public final class GeminiScreenQuestioning: ScreenQuestioning, @unchecked Sendable {
    private let clients: [(model: String, client: LLMClient)]
    private let lock = NSLock()
    private var setAside: [String: Date] = [:]
    private static let fastModels = ["gemini-3.5-flash-lite", "gemini-2.5-flash", "gemini-flash-lite-latest"]

    init?(configuration: Configuration? = try? Configuration.load()) {
        guard let configuration else { return nil }
        let session = QuickSession.shared
        var names = Self.fastModels
        if !names.contains(configuration.model) { names.append(configuration.model) }
        clients = names.map { name in
            (name, LLMClient(config: Configuration(apiKey: configuration.apiKey, model: name, projectRoot: configuration.projectRoot), session: session,
                             gateway: LLMGateway(transport: URLSessionTransport(session: session), backoffPolicy: BackoffPolicy(initialDelay: 1, maxDelay: 2, maxAttempts: 1), provider: "gemini")))
        }
    }

    public func answer(question: String, screenshot: Data, mimeType: String) async throws -> String {
        let prompt = """
        This is the current screen of a phone app. Answer the question below from what is visible, in at most 100 words. Give exact visible text in quotes, \
        and say where things are (top, middle, bottom, left, right). If you cannot tell from the picture, say so instead of guessing.
        Question: \(question)
        """
        let request = LLMRequest(messages: [LLMMessage(text: prompt, imagePNG: screenshot, imageMIMEType: mimeType)], temperature: 0)
        var lastError: Error?
        for (model, client) in clients where isAvailable(model) {
            do { return try await client.complete(request).trimmingCharacters(in: .whitespacesAndNewlines) }
            catch {
                lastError = error
                lock.withLock { setAside[model] = Date().addingTimeInterval(600) }
            }
        }
        throw lastError ?? URLError(.timedOut)
    }

    private func isAvailable(_ model: String) -> Bool {
        lock.withLock {
            guard let until = setAside[model] else { return true }
            if until > Date() { return false }
            setAside[model] = nil
            return true
        }
    }
}
