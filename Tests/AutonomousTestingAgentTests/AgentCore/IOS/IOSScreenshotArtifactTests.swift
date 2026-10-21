import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Screenshots as artifacts")
struct IOSScreenshotArtifactTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    private func store() -> (FileArtifactStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        return (FileArtifactStore(directory: dir), dir)
    }

    @Test func testScreenshotIsStoredAsAChecksummedArtifactAndReturnedAsAReference() async throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let driver = FileScreenshotDriver(screenshotBytes: png)
        let executor = IOSTestSupport.executor(driver: driver, store: store)
        let ctx = IOSActionContext(toolName: "capture_screenshot", executionID: "x1", association: ArtifactAssociation(runID: "run-1", scenarioID: "S1", stepID: "step-1"))
        let exec = try await executor.execute(.screenshot(ScreenshotAction(reason: "verification")), context: ctx)
        let ref = try #require(exec.result.evidence.first)
        #expect(ref.kind == .screenshot && ref.checksum == IntegrityHash.sha256Hex(png))
        let stored = try await store.artifact(id: ref.id)
        #expect(stored.association == ArtifactAssociation(runID: "run-1", scenarioID: "S1", stepID: "step-1") && stored.byteCount == png.count)
        #expect(try await store.load(id: ref.id) == png)
        // The result carries a reference and small facts only: never bytes, never a filesystem path.
        #expect(exec.output.payload?["artifactID"] == .string(ref.id) && exec.output.payload?["screenshotPath"] == nil)
        #expect(!exec.output.summary.contains(driver.screenshotURL!.path))
    }

    @Test func testWithoutAStoreTheLegacyPathIsReturnedAndNothingIsWritten() async throws {
        let driver = FileScreenshotDriver(screenshotBytes: png)
        let exec = try await IOSTestSupport.executor(driver: driver).execute(.screenshot(ScreenshotAction(reason: "r")), context: IOSActionContext())
        #expect(exec.output.payload?["screenshotPath"] == .string(driver.screenshotURL!.path) && exec.result.evidence.isEmpty)
    }

    @Test func testMissingImageFileFailsClosedInsteadOfClaimingSuccess() async {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let executor = IOSTestSupport.executor(driver: FileScreenshotDriver(screenshotBytes: nil), store: store)
        do { _ = try await executor.execute(.screenshot(ScreenshotAction(reason: "r")), context: IOSActionContext()); Issue.record("must fail") }
        catch { #expect(ActionFailureKind.of(error) == .observationFailed) }
    }

    @Test func testRegistryReturnsScreenshotsAsArtifactReferencesOnTheToolResult() async throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: FileScreenshotDriver(screenshotBytes: png), artifactStore: store)
        let result = try await registry.executeReadOnly(
            toolCall: ToolCall(id: "c", name: "capture_screenshot", arguments: ["reason": "evidence"]),
            executionID: "e1", association: ArtifactAssociation(runID: "r", scenarioID: "S", stepID: "st"))
        #expect(result.artifacts.count == 1 && result.toolName == "capture_screenshot" && result.executionID == "e1")
        let all = await store.artifacts(runID: "r")
        #expect(all.count == 1 && all[0].association.stepID == "st")
    }

    @Test func testScreenshotsAreEvidenceNotInstructions() {
        // A screenshot's bytes and path never reach proposal, skill or recovery code.
        for file in SourceTree.core where file.inLayer("Pipelines") || file.layer == "Skills" || file.inLayer("Recovery") {
            for forbidden in ["ScreenshotAction", "screenshotPath", "ArtifactStoring", "captureScreenshot"] {
                #expect(!file.symbols.contains(forbidden), "\(file.path) must not consume screenshots: \(forbidden)")
            }
        }
    }
}
