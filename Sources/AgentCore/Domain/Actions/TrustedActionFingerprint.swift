import Foundation

/// Represents the deterministic, trusted identity of a proposed UI action.
/// It is computed exclusively by trusted Swift application code from canonical action attributes,
/// guaranteeing that LLM prompt injection or synthetic control fields cannot influence deduplication.
public struct TrustedActionFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let scenarioID: String
    public let snapshotID: String
    public let elementID: String
    public let toolName: String
    public let canonicalArguments: String

    public init(
        scenarioID: String,
        snapshotID: String,
        elementID: String,
        toolName: String,
        arguments: [String: AnyCodableValue] = [:]
    ) {
        self.scenarioID = scenarioID
        self.snapshotID = snapshotID
        self.elementID = elementID
        self.toolName = toolName.replacingOccurrences(of: "-", with: "_").lowercased()

        // Canonical serialization of arguments (sorted keys for deterministic hashing)
        // snapshotID and elementID are excluded from canonicalArguments because they are already first-class identity properties
        let filteredArgs = arguments.filter { $0.key != "snapshotID" && $0.key != "elementID" }
        let sortedKeys = filteredArgs.keys.sorted()
        let pairs = sortedKeys.map { key in
            // Typed text is never part of an identity that is logged or persisted (the fingerprint appears in traces).
            let valStr = Self.sensitiveKeys.contains(key) ? "<REDACTED_TEXT>" : Self.canonicalize(filteredArgs[key])
            return "\(key)=\(valStr)"
        }
        self.canonicalArguments = pairs.joined(separator: "&")
    }

    private static let sensitiveKeys: Set<String> = ["text"]

    public var description: String {
        "[\(scenarioID):\(snapshotID):\(elementID):\(toolName)(\(canonicalArguments))]"
    }

    private static func canonicalize(_ value: AnyCodableValue?) -> String {
        guard let value = value else { return "null" }
        switch value {
        case .string(let s):
            return "\"\(s)\""
        case .int(let i):
            return "\(i)"
        case .double(let d):
            return "\(d)"
        case .bool(let b):
            return "\(b)"
        case .array(let arr):
            return "[" + arr.map { canonicalize($0) }.joined(separator: ",") + "]"
        case .dictionary(let dict):
            let sortedKeys = dict.keys.sorted()
            let pairs = sortedKeys.map { "\($0):\(canonicalize(dict[$0]))" }
            return "{" + pairs.joined(separator: ",") + "}"
        case .null:
            return "null"
        }
    }
}

public extension ActionProposal {
    var fingerprint: TrustedActionFingerprint {
        TrustedActionFingerprint(
            scenarioID: scenarioID,
            snapshotID: snapshotID,
            elementID: elementID,
            toolName: toolName,
            arguments: arguments
        )
    }
}
