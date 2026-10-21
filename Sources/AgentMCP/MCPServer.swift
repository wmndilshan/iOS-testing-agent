import Foundation
import AgentCore
import AgentGateway

/// What the server says about itself in the handshake.
public struct MCPServerInfo: Sendable {
    public let name: String
    public let version: String
    /// Shown to the client's model: how to use the tools well.
    public let instructions: String

    public init(name: String, version: String, instructions: String) {
        self.name = name
        self.version = version
        self.instructions = instructions
    }
}

/// The Model Context Protocol, server side, over JSON-RPC 2.0: the handshake, `ping`, `tools/list` and `tools/call` (with progress and cancellation).
/// It has no transport: messages come in through `receive` and go out through the `send` closure, so a test drives it without a pipe.
public actor MCPServer {
    /// Protocol versions this server speaks, newest first. The client's version is echoed when it is one of them, else the newest is offered.
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let gateway: Gateway
    private let info: MCPServerInfo
    private let send: @Sendable (Data) -> Void
    private var running: [String: Task<Void, Never>] = [:]

    public init(gateway: Gateway, info: MCPServerInfo, send: @escaping @Sendable (Data) -> Void) {
        self.gateway = gateway
        self.info = info
        self.send = send
    }

    /// Handles one JSON message (a request or a notification). Long calls run in their own task so `ping` and cancellation stay responsive.
    public func receive(_ message: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] else {
            reply(error: -32700, "Parse error: the message is not a JSON object.", id: .null)
            return
        }
        guard let method = object["method"] as? String else { return }   // a response to us: this server asks nothing
        let id = object["id"].flatMap(Self.value)
        let params = object["params"] as? [String: Any] ?? [:]
        guard let id else {
            notification(method, params)
            return
        }
        switch method {
        case "initialize": reply(result: initialize(params), id: id)
        case "ping": reply(result: [:], id: id)
        case "tools/list": reply(result: ["tools": gateway.tools.map(Self.describe)], id: id)
        case "tools/call": call(params, id: id)
        case "prompts/list": reply(result: ["prompts": GatewayPrompts.all.map(Self.describe)], id: id)
        case "prompts/get": getPrompt(params, id: id)
        case "resources/list" where gateway.resources != nil: reply(result: ["resources": gateway.resources?.list().map(Self.describe) ?? []], id: id)
        case "resources/read" where gateway.resources != nil: readResource(params, id: id)
        default: reply(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    // MARK: Methods

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let asked = params["protocolVersion"] as? String ?? ""
        return [
            "protocolVersion": Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0],
            "capabilities": capabilities(),
            "serverInfo": ["name": info.name, "version": info.version],
            "instructions": info.instructions,
        ]
    }

    private func capabilities() -> [String: Any] {
        var found: [String: Any] = ["tools": ["listChanged": false], "prompts": ["listChanged": false]]
        if gateway.resources != nil { found["resources"] = ["subscribe": false, "listChanged": false] }
        return found
    }

    private func getPrompt(_ params: [String: Any], id: AnyCodableValue) {
        guard let name = params["name"] as? String, let prompt = GatewayPrompts.prompt(named: name) else { reply(error: -32602, "Unknown prompt.", id: id); return }
        let arguments = (params["arguments"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        guard let text = GatewayPrompts.render(prompt, arguments: arguments) else { reply(error: -32602, "Missing a required argument for \(name).", id: id); return }
        reply(result: ["description": prompt.description, "messages": [["role": "user", "content": ["type": "text", "text": text]]]], id: id)
    }

    private func call(_ params: [String: Any], id: AnyCodableValue) {
        guard let name = params["name"] as? String else {
            reply(error: -32602, "tools/call needs a tool name.", id: id)
            return
        }
        let arguments = Self.arguments(from: params["arguments"])
        guard let arguments else {
            reply(error: -32602, "arguments must be a JSON object.", id: id)
            return
        }
        let progressToken = (params["_meta"] as? [String: Any])?["progressToken"].flatMap(Self.value)
        let key = Self.key(id)
        let gateway = self.gateway
        let sender = send
        running[key] = Task { [weak self] in
            let result = await gateway.call(name, arguments: arguments, progress: { message, fraction in
                guard let progressToken else { return }
                var body: [String: Any] = ["progressToken": Self.foundation(progressToken), "progress": fraction ?? 0, "message": message]
                if fraction != nil { body["total"] = 1 }
                sender(Self.encode(["jsonrpc": "2.0", "method": "notifications/progress", "params": body]))
            })
            await self?.finish(key: key, id: id, result: result)
        }
    }

    private func readResource(_ params: [String: Any], id: AnyCodableValue) {
        guard let uri = params["uri"] as? String else { reply(error: -32602, "resources/read needs a uri.", id: id); return }
        guard let contents = gateway.resources?.read(uri: uri) else { reply(error: -32002, "Resource not found: \(uri)", id: id); return }
        reply(result: ["contents": [["uri": contents.uri, "mimeType": contents.mimeType, "text": contents.text]]], id: id)
    }

    private func finish(key: String, id: AnyCodableValue, result: GatewayResult) {
        guard running.removeValue(forKey: key) != nil else { return }   // cancelled: the client no longer wants an answer
        reply(result: Self.content(result), id: id)
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        guard method == "notifications/cancelled", let id = params["requestId"].flatMap(Self.value) else { return }
        let key = Self.key(id)
        running.removeValue(forKey: key)?.cancel()
    }

    // MARK: Encoding

    private func reply(result: [String: Any], id: AnyCodableValue) { send(Self.encode(["jsonrpc": "2.0", "id": Self.foundation(id), "result": result])) }

    private func reply(error code: Int, _ message: String, id: AnyCodableValue) {
        send(Self.encode(["jsonrpc": "2.0", "id": Self.foundation(id), "error": ["code": code, "message": message]]))
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }

    /// A request id (a number or a string) as a Sendable value, and back to the form JSONSerialization writes.
    static func value(_ any: Any) -> AnyCodableValue? {
        guard JSONSerialization.isValidJSONObject([any]), let data = try? JSONSerialization.data(withJSONObject: [any]) else { return nil }
        return (try? JSONDecoder().decode([AnyCodableValue].self, from: data))?.first
    }

    static func foundation(_ value: AnyCodableValue) -> Any {
        switch value {
        case .string(let text): text
        case .int(let number): number
        case .double(let number): number
        case .bool(let flag): flag
        case .null: NSNull()
        case .array(let items): items.map(foundation)
        case .dictionary(let fields): fields.mapValues(foundation)
        }
    }

    private static func key(_ id: AnyCodableValue) -> String { "\(id)" }

    static func describe(_ tool: GatewayTool) -> [String: Any] {
        let schema = (try? JSONEncoder().encode(tool.inputSchema)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        return ["name": tool.name, "description": tool.description, "inputSchema": schema, "annotations": ["readOnlyHint": tool.readOnly]]
    }

    static func describe(_ prompt: GatewayPrompts.Prompt) -> [String: Any] {
        ["name": prompt.name, "description": prompt.description,
         "arguments": prompt.arguments.map { ["name": $0.name, "description": $0.description, "required": $0.required] }]
    }

    static func describe(_ resource: GatewayResources.Resource) -> [String: Any] {
        ["uri": resource.uri, "name": resource.name, "description": resource.description, "mimeType": resource.mimeType]
    }

    static func content(_ result: GatewayResult) -> [String: Any] {
        let parts: [[String: Any]] = result.content.map { part in
            switch part {
            case .text(let text): ["type": "text", "text": text]
            case .image(let base64, let mime): ["type": "image", "data": base64, "mimeType": mime]
            }
        }
        return ["content": parts, "isError": result.isError]
    }

    /// Tool arguments as the gateway's value type; absent means none, anything but an object is refused (nil).
    static func arguments(from raw: Any?) -> [String: AnyCodableValue]? {
        guard let raw, !(raw is NSNull) else { return [:] }
        guard raw is [String: Any], JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode([String: AnyCodableValue].self, from: data)
    }
}
