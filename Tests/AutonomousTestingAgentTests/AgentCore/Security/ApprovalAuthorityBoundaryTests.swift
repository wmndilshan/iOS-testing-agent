import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Approval authority boundary")
struct ApprovalAuthorityBoundaryTests {
    @Test("Public approval construction is pending-only and controller state is not publicly settable")
    func testSourceBoundary() throws {
        let request = try #require(SourceTree.core.first { $0.name == "HITLApprovalRequest.swift" })
        let controller = try #require(SourceTree.core.first { $0.name == "ScenarioExecutionController.swift" })

        #expect(!request.code.contains("public init(\n        status:"))
        #expect(!request.code.contains("status: HITLApprovalStatus ="))
        #expect(request.code.contains("public fileprivate(set) var status"))
        #expect(request.code.contains("enum HITLApprovalAuthority"))
        #expect(!request.code.contains("public enum HITLApprovalAuthority"))
        #expect(controller.code.contains("public private(set) var activeApproval"))
        #expect(controller.code.contains("package func approveCurrentStep(source:"))
    }

    @Test("Reconstructing identical public fields cannot recreate an approved grant")
    func testPublicReconstructionDoesNotCarryAuthority() {
        let now = Date(timeIntervalSince1970: 8_000_000)
        let original = HITLApprovalRequest(
            actionName: "tap", toolName: "tap_element", boundTestCaseID: "S", reason: "r",
            targetApp: ProductFixtures.bundleID, snapshotID: "snap", createdAt: now
        ).transitionedForTest(to: .approved, at: now)

        let reconstructed = HITLApprovalRequest(
            id: original.id, actionName: original.actionName, toolName: original.toolName,
            boundTestCaseID: original.boundTestCaseID, reason: original.reason,
            targetApp: original.targetApp, snapshotID: original.snapshotID,
            arguments: original.arguments, targetLocator: original.targetLocator,
            createdAt: original.createdAt, expiresAt: original.expiresAt
        )

        #expect(original.status == .approved)
        #expect(original.authorizationGrant != nil)
        #expect(reconstructed.status == .pending)
        #expect(reconstructed.authorizationGrant == nil)
    }

    @Test("An approved grant is exact and single-use")
    func testGrantIsSingleUse() {
        let now = Date(timeIntervalSince1970: 8_000_000)
        var request = HITLApprovalRequest(
            actionName: "tap", toolName: "tap_element", reason: "r",
            targetApp: ProductFixtures.bundleID, createdAt: now
        )
        let context = AuthorizationContext(bundleID: ProductFixtures.bundleID,
                                           simulatorUDID: SimulatorTargetConfiguration.current.udid,
                                           executionMode: .simulation,
                                           executionID: "single-use")
        #expect(HITLApprovalAuthority.approve(&request, source: .testAuthority,
                                              context: context, at: now))
        let grant = request.authorizationGrant
        #expect(grant != nil)
        guard let grant else { return }
        #expect(HITLApprovalAuthority.consume(&request, grant: grant))
        #expect(request.status == .executing)
        #expect(!HITLApprovalAuthority.consume(&request, grant: grant))
    }
}
