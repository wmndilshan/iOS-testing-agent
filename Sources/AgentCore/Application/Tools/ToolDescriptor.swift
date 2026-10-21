import Foundation

/// Whether a tool can change the app or simulator.
public enum ToolRisk: Sendable, Equatable {
    case readOnly
    case mutating
}

public enum ToolCategory: String, Sendable, Equatable, CaseIterable {
    case project, observation, interaction, capture, synchronization
}

/// The platform a tool operates on. New integrations (design tools, issue trackers, code analysis) add
/// their own platform and live behind Infrastructure adapters.
public enum ToolPlatform: String, Sendable, Equatable, CaseIterable {
    case ios, host
}

/// Honest availability of a tool on a real simulator. Set only from evidence; a test asserts which tools may
/// claim `liveVerified`.
public enum LiveAvailability: String, Sendable, Equatable, CaseIterable {
    /// A real simulator ran the action through the driver, it happened, a fresh observation changed and trusted
    /// verification passed.
    case liveVerified = "LIVE_VERIFIED"
    /// Implemented for live execution, but no recorded live run proves it.
    case implementedNotLiveVerified = "IMPLEMENTED_NOT_LIVE_VERIFIED"
    /// Works only in simulation; live mode refuses (fails closed) rather than report a false success.
    case simulationOnly = "SIMULATION_ONLY"
    /// Not a device capability (runs on the host).
    case notApplicable = "NOT_APPLICABLE"
}

/// One declared input field of a tool. Schemas are trusted data, never model output.
/// The kinds of value a tool argument can carry.
public enum ToolFieldType: String, Sendable, Equatable {
    case string, number, boolean
}

public struct ToolField: Sendable, Equatable {
    public let name: String
    public let type: ToolFieldType
    public let required: Bool
    public let summary: String
    public let allowedValues: [String]?

    public init(_ name: String, _ type: ToolFieldType, required: Bool, _ summary: String = "", allowedValues: [String]? = nil) {
        self.name = name
        self.type = type
        self.required = required
        self.summary = summary
        self.allowedValues = allowedValues
    }
}

/// Everything trusted code knows about a tool: identity, version, classification, platform, approval
/// policy and the strict input schema. Unknown input fields are always rejected.
public struct ToolDescriptor: Sendable, Equatable {
    /// The stable name models and scenarios use today (e.g. `tap_element`).
    public let name: String
    /// The namespaced name (e.g. `ios.tap`). Metadata only for now; resolution still uses `name` (staged migration).
    public let canonicalName: String
    public let version: Int
    public let category: ToolCategory
    public let platform: ToolPlatform
    public let risk: ToolRisk
    public let live: LiveAvailability
    public let summary: String
    public let input: [ToolField]
    /// What the result carries (documentation of the output contract; results are always `ToolResult`).
    public let output: String

    public init(name: String, canonicalName: String, version: Int, category: ToolCategory, platform: ToolPlatform, risk: ToolRisk,
                live: LiveAvailability, summary: String, input: [ToolField], output: String) {
        self.name = name
        self.canonicalName = canonicalName
        self.version = version
        self.category = category
        self.platform = platform
        self.risk = risk
        self.live = live
        self.summary = summary
        self.input = input
        self.output = output
    }

    /// Mutating tools run only with trusted authorization; read-only tools may run without an approval.
    public var requiresApproval: Bool { risk == .mutating }

    /// A mutating tool invalidates the observation it acted on: a fresh observation and trusted verification
    /// are required before anything else is proposed.
    public var requiresFreshObservationAfter: Bool { risk == .mutating }

    public var fieldNames: Set<String> { Set(input.map(\.name)) }
}

/// Strict validation of a call's arguments against the tool's trusted schema.
public struct ToolInputValidator: Sendable {
    public init() {}

    /// Returns `nil` when the arguments satisfy the schema, else the reason. Rejects unknown fields,
    /// missing required fields, wrong types and values outside a field's allowed set.
    public func violation(of descriptor: ToolDescriptor, arguments: [String: AnyCodableValue]) -> String? {
        let known = Dictionary(uniqueKeysWithValues: descriptor.input.map { ($0.name, $0) })
        if let unknown = arguments.keys.filter({ known[$0] == nil }).sorted().first {
            return "\(descriptor.name) does not accept field '\(unknown)'."
        }
        for field in descriptor.input {
            guard let value = arguments[field.name] else {
                if field.required { return "\(descriptor.name) requires '\(field.name)'." }
                continue
            }
            switch (field.type, value) {
            case (.string, .string(let s)):
                if let allowed = field.allowedValues, !allowed.contains(s.lowercased()) {
                    return "\(descriptor.name) field '\(field.name)' must be one of \(allowed.joined(separator: ", "))."
                }
            case (.number, .int), (.number, .double), (.boolean, .bool):
                break
            default:
                return "\(descriptor.name) field '\(field.name)' must be \(field.type.rawValue)."
            }
        }
        return nil
    }
}

/// Resolves a call to its trusted descriptor and validates its input. The single lookup + validation
/// point: nothing runs against a tool that is not in the catalog or whose input violates its schema.
public struct ToolResolver: Sendable {
    public struct Resolved: Sendable {
        public let descriptor: ToolDescriptor
        public let call: ToolCall
    }

    public init() {}

    public func resolve(_ call: ToolCall) throws -> Resolved {
        guard let descriptor = ToolCatalog.descriptor(for: call.name) else {
            throw ToolRegistryError.toolNotFound(call.name)
        }
        if let reason = ToolInputValidator().violation(of: descriptor, arguments: call.arguments) {
            throw ToolRegistryError.invalidArguments(reason)
        }
        return Resolved(descriptor: descriptor, call: call)
    }
}
