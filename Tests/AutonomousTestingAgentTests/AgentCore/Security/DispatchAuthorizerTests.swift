import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("55. Dispatch Authorizer, Approval Policy & Integrity Hash Tests")
struct DispatchAuthorizerTests {

    private let step = ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!.steps[0]
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func approval(
        status: HITLApprovalStatus = .approved,
        tool: String? = nil,
        snapshot: String? = "snap_1",
        target: TargetElementLocatorDetails? = TargetElementLocatorDetails(elementID: "elem_29", role: "button", identifier: "change-language-dropdown-button"),
        expiresIn: TimeInterval = 60
    ) -> HITLApprovalRequest {
        HITLApprovalRequest(
            actionName: "tap", toolName: tool ?? step.toolName, reason: "test", targetApp: ProductFixtures.bundleID,
            snapshotID: snapshot, targetLocator: target,
            createdAt: now, expiresAt: now.addingTimeInterval(expiresIn)
        ).transitionedForTest(to: status, at: now)
    }

    private func observation(snapshot: String = "snap_1", elements: [UIElementSnapshot]? = nil) -> Observation {
        Observation(snapshotID: snapshot, bundleID: ProductFixtures.bundleID, appState: .runningForeground,
                    elements: elements ?? [ProductFixtures.dropdown, ProductFixtures.closeButton])
    }

    private func rejection(_ decision: DispatchAuthorizer.Decision) -> DispatchAuthorizer.Rejection? {
        if case .rejected(let r) = decision { return r }
        return nil
    }

    // MARK: DispatchAuthorizer

    @Test("A fresh, matching, approved request is authorized and resolves its target")
    func testAuthorizesMatchingApproval() {
        let decision = DispatchAuthorizer().authorize(approval: approval(), step: step, observation: observation(), now: now)
        guard case .authorized(let ok) = decision else { Issue.record("expected authorized"); return }
        #expect(ok.target?.id == "elem_29")
    }

    @Test("Expired approvals are rejected and marked expired")
    func testRejectsExpired() {
        let r = rejection(DispatchAuthorizer().authorize(approval: approval(expiresIn: 60), step: step, observation: observation(), now: now.addingTimeInterval(61)))
        #expect(r?.newStatus == .expired)
        #expect(r?.blockedReason == ApprovalPolicy.expiredMessage)
    }

    @Test("Denied and not-yet-approved requests are rejected")
    func testRejectsDeniedAndPending() {
        let denied = rejection(DispatchAuthorizer().authorize(approval: approval(status: .denied), step: step, observation: observation(), now: now))
        #expect(denied != nil && denied?.newStatus == nil)
        let pending = rejection(DispatchAuthorizer().authorize(approval: approval(status: .pending), step: step, observation: observation(), now: now))
        #expect(pending?.newStatus == .failed)
    }

    @Test("Missing observation, tool mismatch, missing/changed target and stale snapshot all fail closed")
    func testFailClosedCases() {
        let auth = DispatchAuthorizer()
        #expect(rejection(auth.authorize(approval: approval(), step: step, observation: nil, now: now)) != nil)
        #expect(rejection(auth.authorize(approval: approval(tool: "some_other_tool"), step: step, observation: observation(), now: now)) != nil)
        #expect(rejection(auth.authorize(approval: approval(), step: step, observation: observation(elements: [ProductFixtures.closeButton]), now: now)) != nil)
        let wrongRole = TargetElementLocatorDetails(elementID: "elem_29", role: "textField")
        #expect(rejection(auth.authorize(approval: approval(target: wrongRole), step: step, observation: observation(), now: now)) != nil)
        let wrongIdentifier = TargetElementLocatorDetails(elementID: "elem_29", role: "button", identifier: "something-else")
        #expect(rejection(auth.authorize(approval: approval(target: wrongIdentifier), step: step, observation: observation(), now: now)) != nil)
        #expect(rejection(auth.authorize(approval: approval(), step: step, observation: observation(snapshot: "snap_2"), now: now)) != nil)
    }

    // MARK: ApprovalPolicy

    @Test("Approval tokens live exactly 120 seconds")
    func testApprovalTTL() {
        #expect(ApprovalPolicy.tokenTimeToLive == 120)
        #expect(ApprovalPolicy.expiryDate(from: now) == now.addingTimeInterval(120))
        #expect(ApprovalPolicy.expiredMessage.contains("120"))
    }

    // MARK: IntegrityHash

    @Test("IntegrityHash is a stable SHA-256 hex digest")
    func testIntegrityHash() {
        #expect(IntegrityHash.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(IntegrityHash.sha256Hex(Data("abc".utf8)) == IntegrityHash.sha256Hex("abc"))
        #expect(IntegrityHash.sha256Hex("abc") != IntegrityHash.sha256Hex("abd"))
    }
}
