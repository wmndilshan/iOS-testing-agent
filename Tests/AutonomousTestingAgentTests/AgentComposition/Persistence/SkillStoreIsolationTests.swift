import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("54. Skill Store Isolation Tests")
@MainActor
struct SkillStoreIsolationTests {

    private static let realSkillsDir = RepositoryRoot.url
        .appendingPathComponent(".skills").standardizedFileURL

    private func fileState() -> [String: Date] {
        var out: [String: Date] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.realSkillsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files { out[f.lastPathComponent] = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        return out
    }



    @Test("The app reaches the real .skills and .runs only through the composition root")
    func testProductionFactoryExplicit() throws {
        let app = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("Sources/GUI/App/AutonomousTestingAgentApp.swift"), encoding: .utf8)
        // The app reads the real .skills and .runs only through the composition root, and no longer builds AgentUIState.
        #expect(app.contains("AppCompositionRoot.fromEnvironment()"))
        #expect(!app.contains("AgentUIState"))
    }
}
