import Foundation
import AgentCore

/// Logging settings, loaded in one place. Nothing else reads logging environment variables.
///
/// - `ATA_LOG_LEVEL`: trace|debug|info|notice|warning|error|fault (default `info`)
/// - `ATA_LOG_CONSOLE`: `1` to write plain lines to standard error (default off)
/// - `ATA_LOG_FILE`: `1` to append JSON lines under the composition root's logs directory (default off)
/// - `ATA_LLM_DIAGNOSTICS`: `1` to add redacted, size-bounded LLM diagnostics (never raw prompts or responses)
public struct LogConfiguration: Sendable, Equatable {
    public var minimumLevel: LogLevel
    public var console: Bool
    public var file: Bool
    public var llmDiagnostics: Bool

    public init(minimumLevel: LogLevel = .info, console: Bool = false, file: Bool = false, llmDiagnostics: Bool = false) {
        self.minimumLevel = minimumLevel
        self.console = console
        self.file = file
        self.llmDiagnostics = llmDiagnostics
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> LogConfiguration {
        func flag(_ key: String) -> Bool { ["1", "true", "yes"].contains(environment[key]?.lowercased() ?? "") }
        return LogConfiguration(
            minimumLevel: environment["ATA_LOG_LEVEL"].flatMap(LogLevel.init(label:)) ?? .info,
            console: flag("ATA_LOG_CONSOLE"), file: flag("ATA_LOG_FILE"), llmDiagnostics: flag("ATA_LLM_DIAGNOSTICS")
        )
    }
}

/// Builds the logger for a configuration. Destinations that are off are simply not created.
public enum LoggerFactory {
    public static func make(_ configuration: LogConfiguration, fileURL: URL?, extra: [any LogDestination] = []) -> any AppLogger {
        var destinations: [any LogDestination] = extra
        if configuration.console { destinations.append(ConsoleLogDestination()) }
        if configuration.file, let fileURL { destinations.append(FileLogDestination(url: fileURL)) }
        guard !destinations.isEmpty else { return NullLogger() }
        return DestinationLogger(minimumLevel: configuration.minimumLevel, destinations: destinations)
    }
}
