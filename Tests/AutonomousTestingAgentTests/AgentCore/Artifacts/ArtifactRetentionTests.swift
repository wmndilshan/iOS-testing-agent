import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Artifact retention lifecycle")
struct ArtifactRetentionTests {
    static func artifact(_ id: String, kind: ArtifactKind = .report, run: String? = nil, mode: String? = nil) -> Artifact {
        Artifact(id: id, kind: kind, source: "s", reference: "\(id).bin", checksum: "c", byteCount: 1, createdAt: Date(timeIntervalSince1970: 0),
                 association: ArtifactAssociation(runID: run), metadata: mode.map { ["mode": $0] } ?? [:])
    }



    @Test func testRunHistoryKeepsTheCLIModeWhenTheTraceHasNone() {
        let trace = RunTrace(runID: "r", scenarioID: "s")
        #expect(RunHistoryRecord.make(from: trace, humanApproved: true, executionMode: "LIVE_HUMAN_APPROVAL").executionMode == "LIVE_HUMAN_APPROVAL")
        #expect(RunHistoryRecord.make(from: trace, humanApproved: true).executionMode == nil)
    }

    @Test func testUnitTestsNeverUseTheRealStores() {
        for f in SourceTree.allTests where f.name != "ArtifactRetentionTests.swift" {
            // Calls (string literals ignored: other audits quote these names).
            for banned in ["AppCompositionRoot(projectRoot: RepositoryRoot", "AppCompositionRoot(projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath", ".production()"] {
                #expect(!f.symbols.contains(banned), Comment(rawValue: "\(f.path): \(banned)"))
            }
            for banned in ["RepositoryRoot.url.appendingPathComponent(\".artifacts", "RepositoryRoot.url.appendingPathComponent(\".runs", "RepositoryRoot.url.appendingPathComponent(\".skills"] {
                #expect(!f.code.contains(banned), Comment(rawValue: "\(f.path): \(banned)"))
            }
        }
    }
}
