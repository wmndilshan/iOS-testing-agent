import Testing
import Foundation
@testable import CodeIntelligence

/// CodeIntelligence is a read-only analysis target: it may parse sources and read git, never execute, approve, dispatch,
/// call a model or the network, and it never becomes a dependency of AgentCore.
@Suite("CodeIntelligence architecture")
struct CodeIntelligenceArchitectureTests {
    static var files: [SourceTree.File] { SourceTree.all.filter { $0.path.hasPrefix("Sources/CodeIntelligence/") } }

    @Test func testTheTargetIsIndependentOfTheAgentAndItsExecutionPath() {
        #expect(Self.files.count > 10)
        for file in Self.files {
            for banned in ["import AgentCore", "import SwiftUI", "import XCTest", "URLSession", "ToolRegistry", "DeviceDriver",
                           "ScenarioExecutionController", "DispatchAuthorizer.Authorized", "approveCurrentStep", "dispatchCurrentStep("] {
                #expect(!file.symbols.contains(banned), "\(file.path) references \(banned)")
            }
            #expect(!file.symbols.contains("print("), "\(file.path): library code does not print")
        }
    }

    @Test func testGitIsTheOnlyProcessAndItIsReadOnly() {
        let launching = Self.files.filter { $0.symbols.contains("Process()") }.map(\.name)
        #expect(launching == ["GitCommandRunner.swift"])
        #expect(GitCommandRunner.allowedSubcommands == ["rev-parse", "diff", "show", "ls-files"])
        let runner = Self.files.first { $0.name == "GitCommandRunner.swift" }!.code
        #expect(runner.contains("GIT_OPTIONAL_LOCKS") && !runner.contains("/bin/sh") && !runner.contains("/bin/zsh"))
    }

    @Test func testAgentCoreDoesNotDependOnCodeIntelligence() {
        for file in SourceTree.core {
            #expect(!file.code.contains("import CodeIntelligence") && !file.code.contains("import SwiftSyntax"), "\(file.path)")
        }
    }

    @Test func testTheCLIPlannerIsStaticAnalysisOnly() throws {
        let planner = try #require(SourceTree.all.first { $0.name == "Engine+TestPlanner.swift" }).symbols
        for banned in ["CLIExecutionMode", "ToolRegistry", "LLMClient", "dispatchCurrentStep", "approveCurrentStep", "SimulatorXCTestDriver", "UITestRunner"] {
            #expect(!planner.contains(banned), "the planner must not reach \(banned)")
        }
    }
}
