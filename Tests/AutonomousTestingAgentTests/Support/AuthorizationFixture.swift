import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Produces `DispatchAuthorizer.Authorized` proofs the only legitimate way: by running an approved,
/// unexpired request through the real `DispatchAuthorizer`. Tests never forge a proof.
enum AuthorizationFixture {
    static let now = Date(timeIntervalSince1970: 5_000_000)

    static func approval(for call: ToolCall, status: HITLApprovalStatus = .approved, expiresIn: TimeInterval = 60,
                         snapshotID: String? = nil) -> HITLApprovalRequest {
        HITLApprovalRequest(
            actionName: "test approval", toolName: call.name, reason: "test",
            targetApp: ProductFixtures.bundleID, snapshotID: snapshotID, arguments: call.arguments,
            createdAt: now, expiresAt: now.addingTimeInterval(expiresIn)
        ).transitionedForTest(to: status, at: now)
    }

    static func step(for call: ToolCall) -> ScenarioStep {
        ScenarioStep(id: "fixture-step", name: "fixture", description: "fixture", toolName: call.name,
                     locator: ScenarioLocator(role: "button"), trustedArguments: call.arguments)
    }

    static let observation = Observation(snapshotID: "fixture-snapshot", bundleID: ProductFixtures.bundleID,
                                         appState: .runningForeground, elements: [])

    static func authorized(for call: ToolCall) -> DispatchAuthorizer.Authorized {
        switch DispatchAuthorizer().authorize(approval: approval(for: call), step: step(for: call),
                                              observation: observation, context: approval(for: call).authorizationGrant!.context,
                                              now: now) {
        case .authorized(let proof): return proof
        case .rejected(let r): preconditionFailure("fixture approval must authorize: \(r)")
        }
    }
}

extension HITLApprovalRequest {
    /// Tests exercise approval states through the real authority instead of forging stored state.
    func transitionedForTest(to status: HITLApprovalStatus, at now: Date = Date(),
                             context: AuthorizationContext? = nil) -> HITLApprovalRequest {
        var copy = self
        let boundContext = context ?? AuthorizationContext(
            bundleID: targetApp, simulatorUDID: SimulatorTargetConfiguration.current.udid,
            executionMode: .simulation, executionID: "test-execution"
        )
        switch status {
        case .pending: break
        case .approved:
            _ = HITLApprovalAuthority.approve(&copy, source: .testAuthority, context: boundContext, at: now)
        case .denied:
            HITLApprovalAuthority.deny(&copy, reason: "Denied by test authority.")
        case .expired:
            HITLApprovalAuthority.expire(&copy)
        case .executing:
            _ = HITLApprovalAuthority.approve(&copy, source: .testAuthority, context: boundContext, at: now)
            if let grant = copy.authorizationGrant { _ = HITLApprovalAuthority.consume(&copy, grant: grant) }
        case .succeeded:
            _ = HITLApprovalAuthority.approve(&copy, source: .testAuthority, context: boundContext, at: now)
            if let grant = copy.authorizationGrant { _ = HITLApprovalAuthority.consume(&copy, grant: grant) }
            HITLApprovalAuthority.succeed(&copy)
        case .failed:
            HITLApprovalAuthority.fail(&copy, reason: "Failed by test authority.")
        }
        return copy
    }
}

extension DispatchAuthorizer {
    /// Compatibility helper for tests not exercising context mismatch directly.
    func authorize(approval: HITLApprovalRequest, step: ScenarioStep,
                   observation: Observation?, now: Date) -> Decision {
        let context = approval.authorizationGrant?.context ?? AuthorizationContext(
            bundleID: approval.targetApp, simulatorUDID: SimulatorTargetConfiguration.current.udid,
            executionMode: .simulation, executionID: "test-execution"
        )
        return authorize(approval: approval, step: step, observation: observation,
                         context: context, now: now)
    }
}
