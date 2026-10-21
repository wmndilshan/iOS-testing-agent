import Foundation

/// Severity of a log event. A deliberately small, ordered set.
///
/// - `trace`: per-item detail useful only while developing (e.g. each element of a snapshot). Off by default.
/// - `debug`: internal decisions and state changes that help diagnose a single run.
/// - `info`: normal lifecycle milestones: a run started, a step dispatched, a request completed.
/// - `notice`: security- or policy-relevant normal events: approval granted, authorization issued, a fail-closed refusal.
/// - `warning`: something unexpected that was handled: a retry, a rate limit, a stale snapshot rejected.
/// - `error`: an operation failed and the caller sees a failure.
/// - `fault`: a broken invariant or integrity failure; should never happen in a correct system.
///
/// Production runs at `info` or above. Logging is observational: a level never changes behavior.
public enum LogLevel: Int, Sendable, Codable, Comparable, CaseIterable {
    case trace = 0, debug, info, notice, warning, error, fault

    public var label: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }

    public init?(label: String) {
        guard let level = LogLevel.allCases.first(where: { $0.label == label.uppercased() }) else { return nil }
        self = level
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
