import Foundation

/// One argument value. Commands carry plain data only, so they can travel between the agent process and the app as JSON.
public enum DeviceValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// A request to a device: which command, with which arguments, on which target (nil means the chat's current target). It is only a
/// request; `DeviceCommandValidator` decides whether it is well-formed and the approval policy whether it may run.
public struct DeviceCommand: Codable, Sendable, Equatable {
    public let kind: DeviceCommandKind
    public var arguments: [String: DeviceValue]
    public var target: String?

    public init(_ kind: DeviceCommandKind, _ arguments: [String: DeviceValue] = [:], target: String? = nil) {
        self.kind = kind
        self.arguments = arguments
        self.target = target
    }

    public func string(_ name: String) -> String? {
        if case .string(let value)? = arguments[name] { return value }
        return nil
    }

    public func number(_ name: String) -> Double? {
        switch arguments[name] {
        case .number(let value)?: return value
        case .string(let value)?: return Double(value)
        default: return nil
        }
    }

    public func integer(_ name: String) -> Int? { number(name).flatMap { $0.rounded() == $0 ? Int($0) : nil } }

    public func bool(_ name: String) -> Bool? {
        if case .bool(let value)? = arguments[name] { return value }
        return nil
    }
}
