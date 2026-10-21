import Foundation
import AgentCore

/// One thing a tool returns to the agent that called it: text, or a picture.
public enum GatewayContent: Sendable, Equatable {
    case text(String)
    /// Base64 data and its media type, for example `image/jpeg`.
    case image(base64: String, mimeType: String)
}

/// What a tool call gives back. `isError` marks a refusal or failure the calling agent should read and react to; it is not a protocol error.
public struct GatewayResult: Sendable, Equatable {
    public var content: [GatewayContent]
    public var isError: Bool

    public init(content: [GatewayContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> GatewayResult { GatewayResult(content: [.text(text)]) }
    public static func error(_ text: String) -> GatewayResult { GatewayResult(content: [.text(text)], isError: true) }

    /// All text parts joined, for the command line and for tests.
    public var plainText: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }
}

/// Reports progress of a long call (a case run): a short message and, when known, how far along it is from 0 to 1.
public typealias GatewayProgress = @Sendable (_ message: String, _ fraction: Double?) -> Void

/// A tool as the gateway offers it. The name, description and input schema are all a client needs; both the MCP server and the command line
/// read this one definition, so they cannot disagree about what a tool is.
public struct GatewayTool: Sendable {
    public let name: String
    public let description: String
    /// A JSON Schema object for the arguments.
    public let inputSchema: AnyCodableValue
    /// True when the tool never changes the device or any file. Clients may use it to skip a confirmation.
    public let readOnly: Bool
    let run: @Sendable ([String: AnyCodableValue], GatewayProgress) async -> GatewayResult

    init(name: String, description: String, properties: [String: AnyCodableValue], required: [String] = [], readOnly: Bool,
         run: @escaping @Sendable ([String: AnyCodableValue], GatewayProgress) async -> GatewayResult) {
        self.name = name
        self.description = description
        self.inputSchema = Schema.object(properties, required: required)
        self.readOnly = readOnly
        self.run = run
    }
}

/// Builders for the JSON Schema fragments tools use.
enum Schema {
    static func string(_ description: String) -> AnyCodableValue { .dictionary(["type": .string("string"), "description": .string(description)]) }
    static func boolean(_ description: String) -> AnyCodableValue { .dictionary(["type": .string("boolean"), "description": .string(description)]) }
    static func integer(_ description: String) -> AnyCodableValue { .dictionary(["type": .string("integer"), "description": .string(description)]) }
    static func number(_ description: String) -> AnyCodableValue { .dictionary(["type": .string("number"), "description": .string(description)]) }
    static func choice(_ options: [String], _ description: String) -> AnyCodableValue {
        .dictionary(["type": .string("string"), "enum": .array(options.map { .string($0) }), "description": .string(description)])
    }
    static func array(of item: AnyCodableValue, _ description: String) -> AnyCodableValue {
        .dictionary(["type": .string("array"), "description": .string(description), "items": item])
    }
    static func object(_ properties: [String: AnyCodableValue], required: [String]) -> AnyCodableValue {
        .dictionary(["type": .string("object"), "properties": .dictionary(properties), "required": .array(required.map { .string($0) })])
    }
}

extension Dictionary where Key == String, Value == AnyCodableValue {
    func string(_ key: String) -> String? { if case .string(let text)? = self[key] { text } else { nil } }
    func int(_ key: String) -> Int? {
        switch self[key] {
        case .int(let value)?: value
        case .double(let value)?: Int(value)
        case .string(let text)?: Int(text)
        default: nil
        }
    }
    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case .bool(let value)?: value
        case .string(let text)?: text.lowercased() == "true" ? true : text.lowercased() == "false" ? false : nil
        default: nil
        }
    }
}
