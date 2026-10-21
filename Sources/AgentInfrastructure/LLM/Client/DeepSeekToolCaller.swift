import Foundation
import AgentCore

extension AnyCodableValue {
    /// The value as a JSON-compatible object for `JSONSerialization`.
    var jsonObject: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(\.jsonObject)
        case .dictionary(let d): return d.mapValues(\.jsonObject)
        case .null: return NSNull()
        }
    }

    /// Reads a decoded JSON object back into a value.
    static func from(json: Any) -> AnyCodableValue {
        switch json {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return Double(n.intValue) == n.doubleValue ? .int(n.intValue) : .double(n.doubleValue)
        case let a as [Any]: return .array(a.map { .from(json: $0) })
        case let d as [String: Any]: return .dictionary(d.mapValues { .from(json: $0) })
        default: return .null
        }
    }
}

/// Failures of a tool-calling request to a chat model.
public enum AgentModelError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body): return "The model returned HTTP \(status): \(body.prefix(300))"
        case .malformed(let text): return "The model's answer could not be read: \(text.prefix(300))"
        }
    }
}

/// Retries a streaming request before the first byte of its answer, so a rate limit or a hiccup does not end an agent run.
enum AgentRequestRetry {
    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? AgentModelError, case .http(let status, _) = error { return [429, 500, 502, 503, 504].contains(status) }
        if let error = error as? URLError { return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code) }
        return false
    }

    /// How long to wait before try `attempt + 1`: 2 s per failed attempt plus up to half a second of jitter, so parallel agents hit by one rate
    /// limit do not all retry in the same instant.
    static func pause(afterAttempt attempt: Int) -> UInt64 {
        UInt64(attempt) * 2_000_000_000 + UInt64.random(in: 0..<500_000_000)
    }
}

/// DeepSeek's OpenAI-style chat completions with tools and streaming. `deepseek-reasoner` streams its reasoning separately.
public struct DeepSeekToolCaller: ToolCallingLLM {
    public let modelName: String
    private let apiKey: String
    private let maxTokens: Int
    private let timeout: TimeInterval
    private let session: URLSession

    public init(apiKey: String, model: String = "deepseek-chat", maxTokens: Int = 8192, timeout: TimeInterval = 150, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.modelName = model
        self.maxTokens = maxTokens
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

    func requestBody(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> [String: Any] {
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            switch message {
            case .user(let text):
                wire.append(["role": "user", "content": text])
            case .assistant(let text, let calls, let reasoning, _):
                var entry: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty {
                    entry["tool_calls"] = calls.map { call -> [String: Any] in
                        let arguments = (try? JSONSerialization.data(withJSONObject: AnyCodableValue.dictionary(call.arguments).jsonObject)) ?? Data("{}".utf8)
                        return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": String(decoding: arguments, as: UTF8.self)]]
                    }
                    // The reasoner needs its own reasoning back while a tool call is being answered.
                    if !reasoning.isEmpty { entry["reasoning_content"] = reasoning }
                }
                wire.append(entry)
            case .toolResult(let callID, _, let content):
                wire.append(["role": "tool", "tool_call_id": callID, "content": content])
            }
        }
        var body: [String: Any] = ["model": modelName, "messages": wire, "max_tokens": maxTokens, "stream": true, "stream_options": ["include_usage": true]]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema.jsonObject]] as [String: Any] }
        }
        return body
    }

    private func stream(system: String, messages: [AgentMessage], tools: [AgentToolSpec],
                        into continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation, produced: inout Bool) async throws {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(system: system, messages: messages, tools: tools))

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentModelError.malformed("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AgentModelError.http(status: http.statusCode, body: body)
        }
        var pending: [Int: (id: String, name: String, arguments: String)] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let usage = object["usage"] as? [String: Any] {
                continuation.yield(.usage(input: usage["prompt_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0, cached: usage["prompt_cache_hit_tokens"] as? Int ?? 0))
            }
            guard let delta = ((object["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any] else { continue }
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { produced = true; continuation.yield(.reasoningDelta(reasoning)) }
            if let text = delta["content"] as? String, !text.isEmpty { produced = true; continuation.yield(.textDelta(text)) }
            for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let index = (call["index"] as? Int) ?? 0
                var entry = pending[index] ?? (id: "", name: "", arguments: "")
                if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String { entry.name += name }
                    if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                }
                pending[index] = entry
            }
        }
        for index in pending.keys.sorted() {
            let entry = pending[index]!
            guard !entry.name.isEmpty else { continue }
            let arguments = entry.arguments.isEmpty ? "{}" : entry.arguments
            guard let data = arguments.data(using: .utf8), let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw AgentModelError.malformed("arguments of \(entry.name) are not JSON: \(arguments)")
            }
            produced = true
            let call = ToolCall(id: entry.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(6))" : entry.id, name: entry.name, arguments: parsed.mapValues { .from(json: $0) })
            continuation.yield(.toolCall(call, opaque: nil))
        }
        continuation.yield(.done)
    }
}
