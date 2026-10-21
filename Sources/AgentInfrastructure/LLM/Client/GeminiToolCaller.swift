import Foundation
import AgentCore

/// Gemini's `streamGenerateContent` with function declarations. Thought summaries stream as reasoning; function calls may come in parallel.
public struct GeminiToolCaller: ToolCallingLLM {
    public let modelName: String
    private let apiKey: String
    private let timeout: TimeInterval
    private let session: URLSession

    public init(apiKey: String, model: String, timeout: TimeInterval = 150, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.modelName = model
        self.timeout = timeout
        self.session = session
    }

    public func respond(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    var produced = false
                    do {
                        try await stream(system: system, messages: messages, tools: tools, into: continuation, produced: &produced)
                        continuation.finish()
                        return
                    } catch {
                        attempt += 1
                        guard !produced, attempt < 3, AgentRequestRetry.isRetryable(error), !Task.isCancelled else {
                            continuation.finish(throwing: error)
                            return
                        }
                        try? await Task.sleep(nanoseconds: AgentRequestRetry.pause(afterAttempt: attempt))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Gemini's schema dialect has no `additionalProperties`; everything else in the schemas used here is accepted as written.
    private static func cleaned(_ schema: AnyCodableValue) -> Any {
        switch schema {
        case .dictionary(let dict): return dict.filter { $0.key != "additionalProperties" }.mapValues { cleaned($0) }
        case .array(let array): return array.map { cleaned($0) }
        default: return schema.jsonObject
        }
    }

    func requestBody(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> [String: Any] {
        var contents: [[String: Any]] = []
        for message in messages {
            switch message {
            case .user(let text):
                contents.append(["role": "user", "parts": [["text": text]]])
            case .assistant(let text, let calls, _, let opaque):
                var parts: [[String: Any]] = []
                if !text.isEmpty { parts.append(["text": text]) }
                for call in calls {
                    var part: [String: Any] = ["functionCall": ["name": call.name, "args": AnyCodableValue.dictionary(call.arguments).jsonObject]]
                    if let signature = opaque[call.id] { part["thoughtSignature"] = signature }
                    parts.append(part)
                }
                if !parts.isEmpty { contents.append(["role": "model", "parts": parts]) }
            case .toolResult(_, let name, let content):
                let answer: [String: Any] = ["functionResponse": ["name": name, "response": ["result": content]]]
                // Results of parallel calls travel together in one user turn.
                if var last = contents.last, last["role"] as? String == "user", var parts = last["parts"] as? [[String: Any]], parts.first?["functionResponse"] != nil {
                    parts.append(answer)
                    last["parts"] = parts
                    contents[contents.count - 1] = last
                } else {
                    contents.append(["role": "user", "parts": [answer]])
                }
            }
        }
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": ["temperature": 0.2, "thinkingConfig": ["includeThoughts": true]],
        ]
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map { ["name": $0.name, "description": $0.description, "parameters": Self.cleaned($0.schema)] as [String: Any] }]]
        }
        return body
    }

    private func stream(system: String, messages: [AgentMessage], tools: [AgentToolSpec],
                        into continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation, produced: inout Bool) async throws {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?alt=sse")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(system: system, messages: messages, tools: tools))

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentModelError.malformed("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AgentModelError.http(status: http.statusCode, body: body)
        }
        var usage: (input: Int, output: Int, cached: Int)?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let meta = object["usageMetadata"] as? [String: Any] {
                usage = (meta["promptTokenCount"] as? Int ?? 0, (meta["candidatesTokenCount"] as? Int ?? 0) + (meta["thoughtsTokenCount"] as? Int ?? 0), meta["cachedContentTokenCount"] as? Int ?? 0)
            }
            guard let content = ((object["candidates"] as? [[String: Any]])?.first?["content"]) as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            for part in parts {
                if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                    let arguments = (call["args"] as? [String: Any] ?? [:]).mapValues { AnyCodableValue.from(json: $0) }
                    produced = true
                    continuation.yield(.toolCall(ToolCall(id: "call_\(UUID().uuidString.prefix(8))", name: name, arguments: arguments), opaque: part["thoughtSignature"] as? String))
                } else if let text = part["text"] as? String, !text.isEmpty {
                    produced = true
                    continuation.yield((part["thought"] as? Bool) == true ? .reasoningDelta(text) : .textDelta(text))
                }
            }
        }
        if let usage { continuation.yield(.usage(input: usage.input, output: usage.output, cached: usage.cached)) }
        continuation.yield(.done)
    }
}
