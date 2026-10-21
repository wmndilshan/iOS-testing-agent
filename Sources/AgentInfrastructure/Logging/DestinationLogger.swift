import Foundation
import AgentCore

/// The concrete `AppLogger`: filters by level, redacts once, then fans out to destinations.
///
/// Redaction happens here, before any destination, so no destination can forget it. It never throws
/// and never blocks execution on a failing destination.
public struct DestinationLogger: AppLogger {
    public let minimumLevel: LogLevel
    private let destinations: [any LogDestination]
    private let redactor: LogRedactor

    public init(minimumLevel: LogLevel, destinations: [any LogDestination], redactor: LogRedactor = LogRedactor()) {
        self.minimumLevel = minimumLevel
        self.destinations = destinations
        self.redactor = redactor
    }

    public func isEnabled(_ level: LogLevel) -> Bool { level >= minimumLevel && !destinations.isEmpty }

    public func log(_ event: LogEvent) {
        guard isEnabled(event.level) else { return }
        let safe = redactor.redact(event)
        for destination in destinations { destination.write(safe) }
    }
}
