import Foundation
import AgentCore

/// File-backed `ArtifactStoring`. Each artifact is `<id>.bin` plus `<id>.json` metadata in one directory.
///
/// Safety: file names are derived from a generated UUID, never from caller input; ids passed in are
/// validated as UUIDs, so a reference can never traverse out of the directory. Reads recompute the
/// SHA-256 and fail on any mismatch. Writes are atomic.
public actor FileArtifactStore: ArtifactStoring {
    private let directory: URL
    private let clock: any ClockProtocol

    public init(directory: URL, clock: any ClockProtocol = SystemClock()) {
        self.directory = directory
        self.clock = clock
    }

    public func save(_ data: Data, kind: ArtifactKind, source: String, association: ArtifactAssociation, metadata: [String: String]) async throws -> Artifact {
        let id = UUID().uuidString
        let artifact = Artifact(
            id: id, kind: kind, source: LogRedactor().scrub(source), reference: "\(id).bin",
            checksum: IntegrityHash.sha256Hex(data), byteCount: data.count, createdAt: Date(timeIntervalSince1970: clock.now().timeIntervalSince1970.rounded(.down)),  // ISO-8601 storage is whole-second
            association: association, metadata: metadata.mapValues { LogRedactor().scrub($0) }
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try AtomicFile.write(data, to: directory.appendingPathComponent(artifact.reference))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(try encoder.encode(artifact), to: metadataURL(id))
        } catch {
            throw ArtifactStoreError.writeFailed
        }
        return artifact
    }

    public func artifact(id: String) async throws -> Artifact {
        try checkedID(id)
        guard let data = try? Data(contentsOf: metadataURL(id)) else { throw ArtifactStoreError.notFound(id) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let artifact = try? decoder.decode(Artifact.self, from: data), artifact.id == id else { throw ArtifactStoreError.notFound(id) }
        return artifact
    }

    public func load(id: String) async throws -> Data {
        let meta = try await artifact(id: id)
        guard meta.reference == "\(id).bin", let data = try? Data(contentsOf: directory.appendingPathComponent(meta.reference)) else {
            throw ArtifactStoreError.notFound(id)
        }
        guard IntegrityHash.sha256Hex(data) == meta.checksum else { throw ArtifactStoreError.integrityMismatch(id) }
        return data
    }

    public func artifacts(runID: String) async -> [Artifact] { all().filter { $0.association.runID == runID } }
    public func artifacts(scenarioID: String) async -> [Artifact] { all().filter { $0.association.scenarioID == scenarioID } }

    private func all() -> [Artifact] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Artifact.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func metadataURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    private func checkedID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw ArtifactStoreError.unsafeReference(id) }
    }
}
