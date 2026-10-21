import Foundation

/// The logging abstraction every layer may use. Infrastructure supplies the implementations.
///
/// Logging is purely observational: `log` cannot throw, returns nothing and must never influence
/// execution, approval or verification. It is not run history, not a run trace and not an audit
/// trail (see LOGGING_ARCHITECTURE.md).
public protocol AppLogger: Sendable {
    func log(_ event: LogEvent)

    /// Cheap pre-check so callers can skip building expensive fields.
    func isEnabled(_ level: LogLevel) -> Bool
}

extension AppLogger {
    public func isEnabled(_ level: LogLevel) -> Bool { true }

    public func log(
        _ level: LogLevel, _ category: LogCategory, _ event: String, _ message: String = "",
        context: LogContext = LogContext(), fields: [String: LogValue] = [:],
        duration: Double? = nil, errorClass: String? = nil
    ) {
        guard isEnabled(level) else { return }
        log(LogEvent(level: level, category: category, event: event, message: message,
                     context: context, fields: fields, durationSeconds: duration, errorClass: errorClass))
    }

    public func debug(_ category: LogCategory, _ event: String, _ message: String = "", context: LogContext = LogContext(), fields: [String: LogValue] = [:]) {
        log(.debug, category, event, message, context: context, fields: fields)
    }
    public func info(_ category: LogCategory, _ event: String, _ message: String = "", context: LogContext = LogContext(), fields: [String: LogValue] = [:], duration: Double? = nil) {
        log(.info, category, event, message, context: context, fields: fields, duration: duration)
    }
    public func notice(_ category: LogCategory, _ event: String, _ message: String = "", context: LogContext = LogContext(), fields: [String: LogValue] = [:]) {
        log(.notice, category, event, message, context: context, fields: fields)
    }
    public func warning(_ category: LogCategory, _ event: String, _ message: String = "", context: LogContext = LogContext(), fields: [String: LogValue] = [:], errorClass: String? = nil) {
        log(.warning, category, event, message, context: context, fields: fields, errorClass: errorClass)
    }
    public func error(_ category: LogCategory, _ event: String, _ message: String = "", context: LogContext = LogContext(), fields: [String: LogValue] = [:], duration: Double? = nil, errorClass: String? = nil) {
        log(.error, category, event, message, context: context, fields: fields, duration: duration, errorClass: errorClass)
    }
    public func fault(_ category: LogCategory, _ event: String, _ message: String = "", context: LogContext = LogContext(), fields: [String: LogValue] = [:], errorClass: String? = nil) {
        log(.fault, category, event, message, context: context, fields: fields, errorClass: errorClass)
    }
}

/// Discards everything. The default wherever a logger is optional, so no layer needs a global logger.
public struct NullLogger: AppLogger {
    public init() {}
    public func log(_ event: LogEvent) {}
    public func isEnabled(_ level: LogLevel) -> Bool { false }
}

/// Adds a base `LogContext` to every event of a wrapped logger (e.g. a run's IDs).
public struct ContextualLogger: AppLogger {
    public let base: any AppLogger
    public let context: LogContext

    public init(_ base: any AppLogger, context: LogContext) {
        self.base = base
        self.context = context
    }

    public func log(_ event: LogEvent) {
        var e = event
        e.context = context.merged(with: event.context)
        base.log(e)
    }
    public func isEnabled(_ level: LogLevel) -> Bool { base.isEnabled(level) }
}

extension AppLogger {
    public func with(_ context: LogContext) -> any AppLogger { ContextualLogger(self, context: context) }
}
