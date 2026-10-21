import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Closed-loop diagnostic identity provenance")
@MainActor
struct ClosedLoopDiagnosticsProvenanceTests {
    private func completedDiagnostic() async throws -> (ClosedLoopDiagnostics, RunTrace, HITLApprovalRequest) {
        let harness = RunHarness()
        harness.begin()
        let before = ProductFixtures.observation("diagnostic-before", [ProductFixtures.dropdown])
        let after = ProductFixtures.observation("diagnostic-after", [ProductFixtures.closeButton])
        let result = await harness.runStep(target: ProductFixtures.dropdown, before: before, after: after)
        guard case .success = result else {
            Issue.record("Expected the trusted test dispatch to succeed")
            throw DiagnosticTestError.dispatchFailed
        }
        return (
            try #require(harness.controller.runDiagnostics.last),
            try #require(harness.controller.activeRunTrace),
            try #require(harness.controller.activeApproval)
        )
    }

    @Test("Diagnostic run identity is the active trace identity")
    func runIdentityUsesActiveTrace() async throws {
        let (diagnostic, trace, _) = try await completedDiagnostic()
        #expect(diagnostic.runID == trace.runID)
    }

    @Test("Diagnostic approval identity is the actual approval identity")
    func approvalIdentityUsesApproval() async throws {
        let (diagnostic, _, approval) = try await completedDiagnostic()
        #expect(diagnostic.approvalID == approval.id.uuidString)
    }

    @Test("Diagnostics do not claim an approval is a proposal identity")
    func proposalIdentityIsNotFabricated() async throws {
        let (diagnostic, _, _) = try await completedDiagnostic()
        let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        #expect(!json.contains("proposalID"))
        #expect(json.contains("approvalID"))
    }

    @Test("Execution identity remains distinct from run and approval identities")
    func executionIdentityIsDistinct() async throws {
        let (diagnostic, trace, approval) = try await completedDiagnostic()
        let executionID = try #require(diagnostic.executionID)
        #expect(executionID != trace.runID)
        #expect(executionID != approval.id.uuidString)
    }

    @Test("Runner identity has its own namespace")
    func runnerIdentityIsDistinct() {
        let diagnostic = makeDiagnostic(runID: "run", approvalID: "approval", executionID: "execution", runnerID: "runner")
        #expect(diagnostic.runnerID == "runner")
        #expect(diagnostic.runnerID != diagnostic.executionID)
        #expect(diagnostic.runnerID != diagnostic.approvalID)
        #expect(diagnostic.runnerID != diagnostic.runID)
    }

    @Test("Unavailable identities are represented as absence")
    func missingIdentitiesRemainNil() {
        let diagnostic = makeDiagnostic(runID: nil, approvalID: nil, executionID: nil, runnerID: nil)
        #expect(diagnostic.runID == nil)
        #expect(diagnostic.approvalID == nil)
        #expect(diagnostic.executionID == nil)
        #expect(diagnostic.runnerID == nil)
    }

    @Test("Diagnostic construction never synthesizes provenance")
    func constructorDoesNotGenerateProvenance() throws {
        let diagnostic = makeDiagnostic(runID: nil, approvalID: nil, executionID: nil, runnerID: nil)
        let encoded = try JSONEncoder().encode(diagnostic)
        let decoded = try JSONDecoder().decode(ClosedLoopDiagnostics.self, from: encoded)
        #expect(decoded.runID == nil)
        #expect(decoded.approvalID == nil)
        #expect(decoded.executionID == nil)
        #expect(decoded.runnerID == nil)
    }

    private func makeDiagnostic(
        runID: String?,
        approvalID: String?,
        executionID: String?,
        runnerID: String?
    ) -> ClosedLoopDiagnostics {
        ClosedLoopDiagnostics(
            runID: runID,
            scenarioID: "scenario",
            stepID: "step",
            snapshotID: "snapshot",
            approvalID: approvalID,
            executionID: executionID,
            runnerID: runnerID,
            driverInvoked: false,
            driverSucceeded: false,
            scenarioVerified: false,
            progressDetected: false
        )
    }

    private enum DiagnosticTestError: Error {
        case dispatchFailed
    }
}
