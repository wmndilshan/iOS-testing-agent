import Foundation

/// A field value. Structured, never a preformatted string blob.
public indirect enum LogValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([LogValue])
    case object([String: LogValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([LogValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: LogValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension LogValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
}

/// One structured log event: what happened (`event`), how important (`level`), in which area
/// (`category`), correlated by `context`, with typed `fields`.
///
/// `event` is a lowercase dotted name such as `execution.dispatch.started`. `message` is short,
/// plain text: no emojis, decoration or newlines (enforced by `LogText.sanitize`).
public struct LogEvent: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var level: LogLevel
    public var category: LogCategory
    public var event: String
    public var message: String
    public var context: LogContext
    public var fields: [String: LogValue]
    public var durationSeconds: Double?
    /// Neutral failure classification (e.g. an `ErrorCategory` or `LLMFailureKind` raw value).
    public var errorClass: String?

    public init(
        timestamp: Date = Date(), level: LogLevel, category: LogCategory, event: String, message: String = "",
        context: LogContext = LogContext(), fields: [String: LogValue] = [:],
        durationSeconds: Double? = nil, errorClass: String? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.event = event
        self.message = LogText.sanitize(message)
        self.context = context
        self.fields = fields
        self.durationSeconds = durationSeconds
        self.errorClass = errorClass
    }

    /// `execution.dispatch.started`: lowercase dotted segments of `[a-z0-9_]`.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)+$"#, options: .regularExpression) != nil
    }
}

/// Plain-text policy for log messages: single line, no emoji or decorative symbols, bounded length.
public enum LogText {
    public static let maxMessageLength = 500

    public static func sanitize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { out.append(" "); continue }
            if scalar.properties.isEmojiPresentation || scalar.properties.isEmoji && scalar.value > 0x2000 { continue }
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            if (0x2190...0x2BFF).contains(scalar.value) || scalar.value == 0xFE0F || scalar.value == 0x200D { continue }
            out.append(scalar)
        }
        var s = String(out).trimmingCharacters(in: .whitespaces)
        if s.count > maxMessageLength { s = String(s.prefix(maxMessageLength)) + "..." }
        return s
    }
}
