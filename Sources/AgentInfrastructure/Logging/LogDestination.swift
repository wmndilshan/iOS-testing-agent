import Foundation
import AgentCore

/// A place log events are written. Implementations receive events that are already redacted.
public protocol LogDestination: Sendable {
    func write(_ event: LogEvent)
}

/// Formats an event as one plain line: `2026-09-20T10:00:00Z INFO execution execution.dispatch.started runID=... msg`.
public enum LogLineFormatter {
    public static func format(_ e: LogEvent) -> String {
        let ts = ISO8601DateFormatter().string(from: e.timestamp)
        var parts = ["\(ts)", e.level.label, e.category.rawValue, e.event]
        for (k, v) in e.context.setFields { parts.append("\(k)=\(v)") }
        if let d = e.durationSeconds { parts.append("duration=\(String(format: "%.3f", d))s") }
        if let c = e.errorClass { parts.append("errorClass=\(c)") }
        for key in e.fields.keys.sorted() { parts.append("\(key)=\(render(e.fields[key]!))") }
        if !e.message.isEmpty { parts.append("msg=\"\(e.message)\"") }
        return parts.joined(separator: " ")
    }

    private static func render(_ v: LogValue) -> String {
        switch v {
        case .string(let s): return s.contains(" ") ? "\"\(s)\"" : s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .array(let a): return "[" + a.map(render).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { "\($0):\(render(o[$0]!))" }.joined(separator: ",") + "}"
        }
    }
}

/// Writes plain lines to standard error, so the CLI's standard output (prompts, reports) is never mixed with logs.
public struct ConsoleLogDestination: LogDestination {
    public init() {}
    public func write(_ event: LogEvent) {
        let line = LogLineFormatter.format(event) + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Appends one JSON object per line. The location is chosen by the composition root, never here.
public final class FileLogDestination: LogDestination, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func write(_ event: LogEvent) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Keeps events in memory. Used by tests and by in-app diagnostics; writes nothing to disk.
public final class InMemoryLogDestination: LogDestination, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogEvent] = []

    public init() {}

    public func write(_ event: LogEvent) {
        lock.lock(); stored.append(event); lock.unlock()
    }

    public var events: [LogEvent] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
