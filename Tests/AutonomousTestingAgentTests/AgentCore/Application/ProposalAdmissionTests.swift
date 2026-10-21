import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Proposal admission")
struct ProposalAdmissionTests {

    private let scenario = ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func proposal(stepIndex: Int? = 0, arguments: [String: AnyCodableValue] = [:], snapshot: String) -> ActionProposal {
        ActionProposal(
            scenarioID: scenario.id, snapshotID: snapshot, elementID: ProductFixtures.dropdown.id,
            expectedRole: ProductFixtures.dropdown.role, expectedIdentifier: ProductFixtures.dropdown.identifier,
            toolName: "tap_element", arguments: arguments, reason: "test", stepIndex: stepIndex
        )
    }

    private func admit(_ p: ActionProposal, obs: Observation, existing: HITLApprovalRequest? = nil,
                       executed: Set<TrustedActionFingerprint> = []) -> ProposalAdmission.Verdict {
        ProposalAdmission(validator: TrustedActionValidator())
            .admit(p, step: scenario.steps[0], stepIndex: 0, observation: obs,
                   existingApproval: existing, executedFingerprints: executed, now: now)
    }

    private func rejection(_ v: ProposalAdmission.Verdict) -> LLMProposalPipelineError? {
        if case .rejected(let e) = v { return e }
        return nil
    }

    @Test func testValidProposalBecomesPendingApprovalBoundToSnapshot() {
        let obs = ProductFixtures.observation("adm", [ProductFixtures.dropdown])
        guard case .accepted(let request) = admit(proposal(snapshot: obs.snapshotID), obs: obs) else {
            Issue.record("expected accepted"); return
        }
        #expect(request.status == .pending, "Admission never approves")
        #expect(request.snapshotID == obs.snapshotID)
        #expect(request.targetLocator?.elementID == ProductFixtures.dropdown.id)
        #expect(request.expiresAt == ApprovalPolicy.expiryDate(from: now))
        #expect(request.arguments["snapshotID"] == .string(obs.snapshotID))
    }

    @Test func testStepOrderingViolationIsRejected() {
        let obs = ProductFixtures.observation("adm", [ProductFixtures.dropdown])
        #expect(rejection(admit(proposal(stepIndex: 1, snapshot: obs.snapshotID), obs: obs)) != nil)
    }

    @Test func testProposalCannotSupplyTrustedIdentifiers() {
        let obs = ProductFixtures.observation("adm", [ProductFixtures.dropdown])
        for key in ProposalAdmission.securitySensitiveKeys {
            let p = proposal(arguments: [key: .string("attacker")], snapshot: obs.snapshotID)
            #expect(rejection(admit(p, obs: obs)) != nil, "'\(key)' must be system-controlled")
        }
    }

    @Test func testIdenticalPendingProposalIsRejectedAsDuplicate() {
        let obs = ProductFixtures.observation("adm", [ProductFixtures.dropdown])
        let p = proposal(snapshot: obs.snapshotID)
        guard case .accepted(let first) = admit(p, obs: obs) else { Issue.record("expected accepted"); return }
        guard case .duplicateProposal? = rejection(admit(p, obs: obs, existing: first)) else {
            Issue.record("expected duplicateProposal"); return
        }
    }

    @Test func testAlreadyExecutedFingerprintIsRejected() {
        let obs = ProductFixtures.observation("adm", [ProductFixtures.dropdown])
        let p = proposal(snapshot: obs.snapshotID)
        guard case .duplicateProposal? = rejection(admit(p, obs: obs, executed: [p.fingerprint])) else {
            Issue.record("expected duplicateProposal"); return
        }
    }

    @Test func testStaleSnapshotFailsValidation() {
        let obs = ProductFixtures.observation("adm", [ProductFixtures.dropdown])
        #expect(rejection(admit(proposal(snapshot: "some_other_snapshot"), obs: obs)) != nil)
    }
}
