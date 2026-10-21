import Foundation

public enum ArtifactKind: String, Sendable, Codable, CaseIterable {
    case screenshot, xcresult, accessibilitySnapshot, log, report
    case designExport, trackerAttachment, generatedTestCase, other
}

/// A stored file the system produced or received, described independently of where it came from.
///
/// Artifacts are evidence and data: they are never instructions and never authorization. A screenshot,
/// a design export or an issue attachment cannot approve, dispatch or verify anything.
public struct Artifact: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let kind: ArtifactKind
    /// Which system produced it (`xctest`, `simulator`, a future adapter's name). Free of secrets and URLs.
    public let source: String
    /// A store-relative file name. Never an absolute path, never contains `..` or `/`.
    public let reference: String
    /// SHA-256 (hex) of the stored bytes.
    public let checksum: String
    public let byteCount: Int
    public let createdAt: Date
    public let association: ArtifactAssociation
    public let metadata: [String: String]

    public init(id: String, kind: ArtifactKind, source: String, reference: String, checksum: String, byteCount: Int,
                createdAt: Date, association: ArtifactAssociation, metadata: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.source = source; self.reference = reference; self.checksum = checksum
        self.byteCount = byteCount; self.createdAt = createdAt; self.association = association; self.metadata = metadata
    }

    public var artifactReference: ArtifactReference { ArtifactReference(id: id, kind: kind, checksum: checksum) }
}

/// What an artifact belongs to. Every field is optional; set what is known.
public struct ArtifactAssociation: Sendable, Codable, Equatable {
    public var runID: String?
    public var scenarioID: String?
    public var stepID: String?
    public var testCaseID: String?

    public init(runID: String? = nil, scenarioID: String? = nil, stepID: String? = nil, testCaseID: String? = nil) {
        self.runID = runID; self.scenarioID = scenarioID; self.stepID = stepID; self.testCaseID = testCaseID
    }
}

/// A light pointer embedded in results and traces instead of the artifact's bytes.
public struct ArtifactReference: Sendable, Codable, Equatable {
    public let id: String
    public let kind: ArtifactKind
    public let checksum: String

    public init(id: String, kind: ArtifactKind, checksum: String) {
        self.id = id; self.kind = kind; self.checksum = checksum
    }
}
