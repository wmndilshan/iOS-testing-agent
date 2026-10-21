import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Semantic-gate contract, Phase 8: proves the semantic-fidelity gate cannot become an execution bypass. Two kinds of
/// evidence: structural (source/type inspection — the gate's own file never imports or names anything
/// execution-adjacent, and nothing in the trusted spine references the gate back) and behavioral (running
/// the gate produces only plain values, never a side effect, never a snapshot/observation/authorization id).
@Suite("IR.20 Semantic-gate contract Semantic Gate Security Boundary")
struct SemanticGateSecurityTests {

    @Test("SemanticExpectation.swift's own source never names a driver, ToolRegistry, or trusted-spine type")
    func testGateSourceNeverReferencesExecutionTypes() throws {
        let path = "Sources/AgentCore/Application/IR/SemanticExpectation.swift"
        let source = try String(contentsOfFile: findRepoFile(path), encoding: .utf8)
        // Only the CODE matters here — the file's own doc comments legitimately name these types to explain
        // that it does NOT use them, so comment lines are excluded before the check.
        let codeOnly = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let forbidden = ["SimulatedDriver", "SimulatorXCTestDriver", "ToolRegistry", "ScenarioExecutionController",
                          "ScenarioStepDispatcher", "DispatchAuthorizer", "ProposalAdmission", "TrustedActionValidator",
                          ".approveCurrentStep", ".dispatchCurrentStep", "HITLApprovalRequest"]
        for name in forbidden {
            #expect(!codeOnly.contains(name), "SemanticExpectation.swift's executable code must never reference '\(name)'")
        }
    }

    @Test("Nothing in the trusted spine, security layer, or infrastructure layer references SemanticFidelityGate or SemanticExpectation — the gate is a dead-end consumer, never a dependency of execution")
    func testTrustedSpineNeverReferencesTheGate() throws {
        let dirs = ["Sources/AgentCore/Application/Orchestration", "Sources/AgentCore/Security", "Sources/AgentInfrastructure"]
        for dir in dirs {
            let fullDir = findRepoFile(dir)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: fullDir).filter { $0.hasSuffix(".swift") }) ?? []
            for file in files {
                let content = (try? String(contentsOfFile: fullDir + "/" + file, encoding: .utf8)) ?? ""
                #expect(!content.contains("SemanticFidelityGate") && !content.contains("SemanticExpectation"),
                        "\(dir)/\(file) must never reference the semantic gate")
            }
        }
    }

    @Test("SemanticFidelityResult/SemanticMismatchDetail carry no snapshotID, observationID, executionID, or authorization-result field — Mirror-inspected, not merely eyeballed")
    func testResultTypesCarryNoExecutionIdentifiers() {
        let result = SemanticFidelityResult(classification: .semanticMismatch, mismatches: [SemanticMismatchDetail(property: "p", expected: "e", actual: "a")])
        let mirror = Mirror(reflecting: result)
        let forbidden = ["snapshotID", "snapshotId", "observationID", "observationId", "executionID", "executionId", "authorized", "approved"]
        func checkNoForbiddenLabels(_ m: Mirror) {
            for child in m.children {
                if let label = child.label {
                    #expect(!forbidden.contains(label), "SemanticFidelityResult (or a nested value) unexpectedly carries a field named '\(label)'")
                }
                checkNoForbiddenLabels(Mirror(reflecting: child.value))
            }
        }
        checkNoForbiddenLabels(mirror)
    }

    private func findRepoFile(_ relativePath: String) -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            dir = dir.deletingLastPathComponent()
        }
        return relativePath
    }
}
