import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Artifact store")
struct ArtifactStoreTests {

    private func makeStore() -> (FileArtifactStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artifacts-\(UUID().uuidString)")
        return (FileArtifactStore(directory: dir), dir)
    }

    @Test func testSaveRecordsChecksumSizeAndAssociation() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("screenshot-bytes".utf8)
        let a = try await store.save(bytes, kind: .screenshot, source: "xctest",
                                     association: ArtifactAssociation(runID: "run-1", scenarioID: "S1", stepID: "step-1", testCaseID: "TC-1"),
                                     metadata: ["reason": "verification"])
        #expect(a.checksum == IntegrityHash.sha256Hex(bytes) && a.byteCount == bytes.count)
        #expect(a.association.runID == "run-1" && a.association.scenarioID == "S1" && a.association.stepID == "step-1" && a.association.testCaseID == "TC-1")
        #expect(a.artifactReference == ArtifactReference(id: a.id, kind: .screenshot, checksum: a.checksum))
    }

    @Test func testArtifactsPersistAndReloadWithVerifiedContent() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await store.save(Data("payload".utf8), kind: .report, source: "test", association: ArtifactAssociation(runID: "r"), metadata: [:])
        let reopened = FileArtifactStore(directory: dir)
        #expect(try await reopened.artifact(id: a.id) == a)
        #expect(try await reopened.load(id: a.id) == Data("payload".utf8))
    }

    @Test func testTamperedContentIsDetectedOnRead() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await store.save(Data("original".utf8), kind: .log, source: "test", association: ArtifactAssociation(), metadata: [:])
        try Data("tampered".utf8).write(to: dir.appendingPathComponent(a.reference))
        await #expect(throws: ArtifactStoreError.integrityMismatch(a.id)) { _ = try await store.load(id: a.id) }
    }

    @Test func testReferencesAreStoreRelativeAndTraversalIsRefused() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await store.save(Data("x".utf8), kind: .other, source: "test", association: ArtifactAssociation(), metadata: [:])
        #expect(a.reference == "\(a.id).bin" && !a.reference.contains("/") && !a.reference.contains(".."))
        for bad in ["../secrets", "/etc/passwd", "a/b", "..", "not-a-uuid"] {
            await #expect(throws: ArtifactStoreError.unsafeReference(bad)) { _ = try await store.artifact(id: bad) }
            await #expect(throws: ArtifactStoreError.unsafeReference(bad)) { _ = try await store.load(id: bad) }
        }
        await #expect(throws: ArtifactStoreError.notFound("00000000-0000-0000-0000-000000000000")) {
            _ = try await store.load(id: "00000000-0000-0000-0000-000000000000")
        }
    }

    @Test func testArtifactsAreQueryableByRunAndScenario() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await store.save(Data("1".utf8), kind: .screenshot, source: "t", association: ArtifactAssociation(runID: "A", scenarioID: "S1"), metadata: [:])
        _ = try await store.save(Data("2".utf8), kind: .xcresult, source: "t", association: ArtifactAssociation(runID: "A", scenarioID: "S2"), metadata: [:])
        _ = try await store.save(Data("3".utf8), kind: .report, source: "t", association: ArtifactAssociation(runID: "B", scenarioID: "S1"), metadata: [:])
        let runA = await store.artifacts(runID: "A"), runB = await store.artifacts(runID: "B")
        let s1 = await store.artifacts(scenarioID: "S1"), none = await store.artifacts(scenarioID: "none")
        #expect(runA.count == 2 && runB.count == 1)
        #expect(s1.count == 2 && none.isEmpty)
    }

    @Test func testSecretsInSourceAndMetadataAreRedactedBeforeStorage() async throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await store.save(Data("x".utf8), kind: .designExport, source: "https://x.test/f?token=abc123", association: ArtifactAssociation(),
                                     metadata: ["note": "api_key=AIzaSyD-1234567890abcdefghijklmnop"])
        #expect(!a.source.contains("abc123") && !(a.metadata["note"] ?? "").contains("AIzaSyD"))
        let onDisk = try String(contentsOf: dir.appendingPathComponent("\(a.id).json"), encoding: .utf8)
        #expect(!onDisk.contains("abc123") && !onDisk.contains("AIzaSyD"))
    }

    @Test func testArtifactsAreEvidenceNotAuthorization() {
        // An artifact carries no capability: results reference it by id/kind/checksum only.
        let ref = ArtifactReference(id: "i", kind: .screenshot, checksum: "c")
        let result = ToolResult(callID: "c", status: .success, summary: "captured", artifacts: [ref])
        #expect(result.artifacts == [ref])
        #expect(Mirror(reflecting: ref).children.allSatisfy { ["id", "kind", "checksum"].contains($0.label ?? "") })
    }

    @Test func testStoreLocationIsChosenByTheCompositionRoot() {
        let root = InfrastructureFactory(projectRoot: URL(fileURLWithPath: "/tmp/ata-root"))
        #expect(root.artifactsDirectory.path == "/tmp/ata-root/.artifacts")
    }
}
