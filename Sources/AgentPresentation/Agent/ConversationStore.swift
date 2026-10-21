import Foundation
import AgentCore

/// What the chat list shows about one conversation.
public struct ConversationSummary: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: Int

    public static let untitled = "New chat"
}

/// One conversation as saved: its transcript, what the agents remember, and the test cases written in it.
struct ConversationRecord: Codable, Sendable {
    var summary: ConversationSummary
    var repository: String
    var memory: AgentMemory
    var messages: [AgentChatMessage]
    var cases: [String: AgentCaseInfo]
}

/// The conversations kept as files in one folder: `index.json` (the list) and `<id>.json` (each transcript). A file that cannot be read is
/// skipped, never fatal: a damaged chat must not stop the app from opening.
struct ConversationStore: Sendable {
    let directory: URL
    static let maxConversations = 100

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    /// Newest first.
    func list() -> [ConversationSummary] {
        guard let data = try? Data(contentsOf: indexURL), let all = try? decoder.decode([ConversationSummary].self, from: data) else { return [] }
        return all.filter { FileManager.default.fileExists(atPath: url($0.id).path) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) -> ConversationRecord? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? decoder.decode(ConversationRecord.self, from: data)
    }

    func save(_ record: ConversationRecord) {
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              let data = try? encoder.encode(record), (try? data.write(to: url(record.summary.id), options: .atomic)) != nil else { return }
        var index = list().filter { $0.id != record.summary.id }
        index.append(record.summary)
        index.sort { $0.updatedAt > $1.updatedAt }
        // The oldest conversations beyond the cap are forgotten, so the folder cannot grow without bound.
        for dropped in index.dropFirst(Self.maxConversations) { try? FileManager.default.removeItem(at: url(dropped.id)) }
        write(Array(index.prefix(Self.maxConversations)))
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        write(list().filter { $0.id != id })
    }

    private func write(_ index: [ConversationSummary]) {
        if let data = try? encoder.encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    private var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    private var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
