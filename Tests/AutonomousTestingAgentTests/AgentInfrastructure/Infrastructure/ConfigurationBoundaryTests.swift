import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Configuration and simulator target boundary")
struct ConfigurationBoundaryTests {
    @Test("Source-relative discovery resolves the repository package root")
    func sourceRelativeRoot() {
        let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = Configuration.resolveProjectRoot(
            environment: [:], currentDirectory: unrelated, sourceFilePath: #filePath
        )
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
        #expect(root.lastPathComponent == "AutonomousTestingAgent")
    }

    @Test("A repository-root working directory resolves to itself")
    func repositoryRootWorkingDirectory() {
        let root = Configuration.resolveProjectRoot(environment: [:], currentDirectory: repositoryRoot)
        #expect(root == repositoryRoot.standardizedFileURL)
    }

    @Test("A folder with TestCases/ is the project even when a package root lies above it, and a missing model key does not change the root")
    func projectFolderBeatsPackageRoot() throws {
        let project = repositoryRoot.appendingPathComponent(".build/project-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("TestCases"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(Configuration.resolveProjectRoot(environment: [:], currentDirectory: project) == project.standardizedFileURL)
        #expect(Configuration.resolveProjectRoot(environment: ["ATA_PROJECT_ROOT": project.path], currentDirectory: repositoryRoot).path == project.standardizedFileURL.path)
        // No key anywhere: loading fails, but the factory still resolves the same root.
        #expect(throws: (any Error).self) { try Configuration.load(environment: ["ATA_PROJECT_ROOT": project.path], currentDirectory: project) }
        #expect(Configuration.resolveProjectRoot(environment: ["ATA_PROJECT_ROOT": project.path]).path == project.standardizedFileURL.path)
    }

    @Test("A nested working directory resolves to its nearest package root")
    func nestedWorkingDirectory() throws {
        let nested = repositoryRoot.appendingPathComponent("Sources/AgentInfrastructure")
        #expect(Configuration.resolveProjectRoot(environment: [:], currentDirectory: nested) == repositoryRoot.standardizedFileURL)
    }

    @Test("An explicit project root has highest priority")
    func explicitOverrideWins() {
        let explicit = FileManager.default.temporaryDirectory.appendingPathComponent("explicit-root")
        let resolved = Configuration.resolveProjectRoot(
            explicitProjectRoot: explicit,
            environment: ["ATA_PROJECT_ROOT": "/ignored"],
            currentDirectory: repositoryRoot
        )
        #expect(resolved == explicit.standardizedFileURL)
    }

    @Test("A missing env file is harmless when required values come from the environment")
    func missingEnvFileIsHarmless() throws {
        let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("no-env-\(UUID().uuidString)")
        let config = try Configuration.load(
            environment: ["LLM_API_KEY": "real-test-key"],
            currentDirectory: emptyRoot,
            explicitProjectRoot: emptyRoot
        )
        #expect(config.projectRoot == emptyRoot.standardizedFileURL)
        #expect(config.apiKey == "real-test-key")
    }

    @Test("Domain target model contains no deployment values or developer path")
    func domainContainsNoDeploymentDiscovery() throws {
        let file = repositoryRoot.appendingPathComponent("Sources/AgentCore/Domain/Runs/SimulatorTarget.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("0F0D6B41"))
        #expect(!source.contains("com.apple.mobilesafari"))
        #expect(!source.contains("/Users/"))
        #expect(!source.contains("ProcessInfo"))
        #expect(!source.contains("FileManager"))
    }


    @Test("Deployed product bundle remains unchanged")
    func productBundleIsStable() {
        #expect(SimulatorTargetConfiguration.current.bundleID == "com.apple.mobilesafari")
    }

    @Test("Deployed fixture bundle remains unchanged")
    func fixtureBundleIsStable() {
        #expect(SimulatorTargetConfiguration.current.previewBundleID == FixtureScenarioCatalog.bundleID)
        #expect(SimulatorTargetConfiguration.current.previewBundleID == "com.autonomous.agent.fixture")
    }

    private var repositoryRoot: URL {
        Configuration.resolveProjectRoot(environment: [:], currentDirectory: URL(fileURLWithPath: "/"), sourceFilePath: #filePath)
    }
}
