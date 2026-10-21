import Foundation
import AgentCore

/// File-backed persistent run history (`<dir>/<runID>.record.json` and `<runID>.trace.json`).
public actor RunHistoryStore: RunHistoryStoring {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func recordURL(_ runID: String) -> URL { directory.appendingPathComponent("\(runID).record.json") }
    private func traceURL(_ runID: String) -> URL { directory.appendingPathComponent("\(runID).trace.json") }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func save(record: RunHistoryRecord, trace: RunTrace?) throws {
        try AtomicFile.write(Self.encoder().encode(record), to: recordURL(record.runID))
        if let trace {
            try AtomicFile.write(Self.encoder().encode(trace), to: traceURL(record.runID))
        }
    }

    public func list() -> [RunHistoryRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = Self.decoder()
        return files
            .filter { $0.lastPathComponent.hasSuffix(".record.json") }
            .compactMap { try? decoder.decode(RunHistoryRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    public func loadTrace(runID: String) -> RunTrace? {
        guard let data = try? Data(contentsOf: traceURL(runID)) else { return nil }
        return try? Self.decoder().decode(RunTrace.self, from: data)
    }

    public func replayRequest(for runID: String) -> ReplayRequest? {
        guard let data = try? Data(contentsOf: recordURL(runID)),
              let record = try? Self.decoder().decode(RunHistoryRecord.self, from: data) else { return nil }
        return ReplayRequest(sourceRunID: record.runID, scenarioID: record.scenarioID)
    }
}
