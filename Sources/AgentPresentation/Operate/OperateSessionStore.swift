import Foundation
import AgentCore

/// A finished or interrupted Operate task, kept so it can be looked at again.
public struct OperateSession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var task: String
    public var startedAt: Date
    /// "running" while it is, then "done", "failed" or "stopped".
    public var status: String
    public var goals: [OperateGoal]
    public var entries: [OperateEntry]
    public var summary: String
    public var usage: OperateUsage
    public var recorded: [RecordedAction]
    public var savedCaseKey: String?
    /// Seconds per part of the team; absent in sessions saved before it was recorded.
    public var workerSeconds: [String: Double]?
}

/// One row of the sessions list.
public struct OperateSessionSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let task: String
    public let startedAt: Date
    public let status: String
}

/// Sessions as one JSON file each under `.runs/operate`. Writes are best effort: a session that cannot be saved is simply not listed later.
public struct OperateSessionStore: Sendable {
    let directory: URL
    static let maxEntries = 400
    static let maxSessions = 60

    public init(directory: URL) { self.directory = directory }

    private var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    private var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ session: OperateSession) {
        var kept = session
        if kept.entries.count > Self.maxEntries { kept.entries = Array(kept.entries.suffix(Self.maxEntries)) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(kept) { try? data.write(to: url(session.id), options: .atomic) }
        prune()
    }

    public func load(_ id: UUID) -> OperateSession? {
        (try? Data(contentsOf: url(id))).flatMap { try? decoder.decode(OperateSession.self, from: $0) }
    }

    /// Newest first.
    public func list() -> [OperateSessionSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { file in (try? Data(contentsOf: file)).flatMap { try? decoder.decode(OperateSession.self, from: $0) } }
            .map { OperateSessionSummary(id: $0.id, task: $0.task, startedAt: $0.startedAt, status: $0.status) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    private func prune() {
        for old in list().dropFirst(Self.maxSessions) { delete(old.id) }
    }
}
