import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Source-level audits that keep the execution surface small: no code compiles Swift or writes into the test tree, no generic command runner
/// exists, and nothing depends on Figma.
@Suite("Execution surface audit")
struct ExecutionSurfaceAuditTests {
    @Test func testNothingCompilesSwiftOrWritesIntoTheTestTree() {
        for f in SourceTree.all {
            #expect(!f.code.contains("appendingPathComponent(\"Tests/"), Comment(rawValue: f.path))
            for banned in ["\"swiftc\"", "/usr/bin/swift\"", "\"swift\", \"test\"", "\"swift\", \"build\""] { #expect(!f.code.contains(banned), Comment(rawValue: "\(f.path): \(banned)")) }
        }
        // Nothing launches xcodebuild any more: the idb driver is the only device path.
        #expect(SourceTree.all.filter { $0.code.contains("\"/usr/bin/xcodebuild\"") }.isEmpty)
    }

    @Test func testNoGenericCommandRunnerExists() {
        for f in SourceTree.all {
            for banned in ["func run(command:", "func run(_ command: String", "func shell(", "func execute(command:", "func runShell", "\"/bin/sh\"", "\"/bin/zsh\"", "\"/bin/bash\""] {
                #expect(!f.code.contains(banned), Comment(rawValue: "\(f.path): \(banned)"))
            }
        }
    }

    @Test func testNothingDependsOnFigma() {
        for f in SourceTree.all {
            for banned in ["import Figma", "figma.com", "FigmaClient", "FigmaAPI"] { #expect(!f.code.contains(banned), Comment(rawValue: "\(f.path): \(banned)")) }
        }
    }
}
