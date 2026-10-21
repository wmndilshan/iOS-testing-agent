import Foundation

/// One tool an agent may call: a name, what it does, and a JSON-schema object describing its arguments.
public struct AgentToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let schema: AnyCodableValue

    public init(name: String, description: String, schema: AnyCodableValue) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

/// One entry of an agent conversation. A tool result answers the assistant call with the same id.
public enum AgentMessage: Sendable, Equatable {
    case user(String)
    /// `reasoning` and `opaque` (call id to a provider token) are handed back to the provider on the next request when it needs them.
    case assistant(text: String, calls: [ToolCall], reasoning: String, opaque: [String: String])
    case toolResult(callID: String, name: String, content: String)
}

/// What a model streams back for one request.
public enum AgentEvent: Sendable, Equatable {
    case reasoningDelta(String)
    case textDelta(String)
    case toolCall(ToolCall, opaque: String?)
    /// Tokens the provider billed for this request; `cached` of the input came from its prompt cache.
    case usage(input: Int, output: Int, cached: Int)
    case done
}

/// A chat model that can call tools and stream its reasoning. Provider-neutral: the wire formats live in Infrastructure.
public protocol ToolCallingLLM: Sendable {
    var modelName: String { get }
    func respond(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error>
}
