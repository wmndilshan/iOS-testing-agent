import Foundation

public enum ArtifactStoreError: Error, Equatable, ErrorCategoryProviding {
    case notFound(String)
    case integrityMismatch(String)
    case unsafeReference(String)
    case writeFailed

    public var errorCategory: ErrorCategory {
        switch self {
        case .notFound, .writeFailed: return .persistence
        case .integrityMismatch, .unsafeReference: return .security
        }
    }
}

/// Stores and retrieves artifacts (screenshots, exports, reports, attachments).
///
/// Separate from `ToolRegistry`: tools that produce large outputs store them here and return an
/// `ArtifactReference`. Implementations verify a checksum on read and refuse unsafe references.
/// The store's location is chosen by the composition root.
public protocol ArtifactStoring: Sendable {
    func save(_ data: Data, kind: ArtifactKind, source: String, association: ArtifactAssociation, metadata: [String: String]) async throws -> Artifact
    func artifact(id: String) async throws -> Artifact
    /// The stored bytes, verified against the recorded checksum.
    func load(id: String) async throws -> Data
    func artifacts(runID: String) async -> [Artifact]
    func artifacts(scenarioID: String) async -> [Artifact]
}
