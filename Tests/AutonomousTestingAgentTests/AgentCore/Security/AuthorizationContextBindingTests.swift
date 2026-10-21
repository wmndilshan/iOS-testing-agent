import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Authorization context binding")
struct AuthorizationContextBindingTests {
    private let now = Date(timeIntervalSince1970: 9_000_000)
    private let step = ScenarioStep(id: "s", name: "tap", description: "tap", toolName: "tap_element",
                                    locator: ScenarioLocator(role: "button", identifier: "button"))

    private func context(bundle: String = ProductFixtures.bundleID, device: String = "DEVICE-A",
                         mode: ExecutionMode = .live, execution: String = "EXEC-A",
                         workflow: String? = nil) -> AuthorizationContext {
        AuthorizationContext(bundleID: bundle, simulatorUDID: device, executionMode: mode,
                             executionID: execution, workflowExecutionID: workflow)
    }

    private func observation(bundle: String = ProductFixtures.bundleID, device: String = "DEVICE-A",
                             snapshot: String = "snap", includeTarget: Bool = true) -> Observation {
        var observation = Observation(snapshotID: snapshot, bundleID: bundle, appState: .runningForeground,
                                      elements: includeTarget ? [ProductFixtures.element("button", identifier: "button")] : [])
        observation.simulatorUDID = device
        return observation
    }

    private func approval(context: AuthorizationContext, tool: String = "tap_element",
                          snapshot: String = "snap",
                          arguments: [String: AnyCodableValue] = ["snapshotID": "snap", "elementID": "button"])
        -> HITLApprovalRequest {
        HITLApprovalRequest(
            actionName: "tap", toolName: tool, boundTestCaseID: "S", reason: "test",
            targetApp: ProductFixtures.bundleID, snapshotID: snapshot, arguments: arguments,
            targetLocator: TargetElementLocatorDetails(elementID: "button", role: "button", identifier: "button"),
            createdAt: now, expiresAt: now.addingTimeInterval(120)
        ).transitionedForTest(to: .approved, at: now, context: context)
    }

    private func accepted(_ approval: HITLApprovalRequest, context: AuthorizationContext,
                          observation: Observation? = nil, step: ScenarioStep? = nil) -> Bool {
        if case .authorized = DispatchAuthorizer().authorize(
            approval: approval, step: step ?? self.step,
            observation: observation ?? self.observation(), context: context, now: now
        ) { return true }
        return false
    }

    @Test("Matching bundle, device, mode and execution identity authorize")
    func testMatchingContextPasses() {
        let bound = context()
        #expect(accepted(approval(boundContext: bound), context: bound))
    }

    @Test("Bundle and observed application mismatches fail closed")
    func testBundleMismatch() {
        let bound = context()
        #expect(!accepted(approval(boundContext: bound), context: context(bundle: "other.bundle")))
        #expect(!accepted(approval(boundContext: bound), context: bound,
                          observation: observation(bundle: "other.bundle")))
    }

    @Test("Approved simulator and current simulator must match")
    func testDeviceMismatch() {
        let bound = context()
        #expect(!accepted(approval(boundContext: bound), context: context(device: "DEVICE-B")))
        #expect(!accepted(approval(boundContext: bound), context: bound,
                          observation: observation(device: "DEVICE-B")))
    }

    @Test("LIVE and SIMULATION approvals cannot cross-authorize")
    func testModeMismatchBothDirections() {
        let live = context(mode: .live)
        let simulated = context(mode: .simulation)
        #expect(!accepted(approval(boundContext: live), context: simulated))
        #expect(!accepted(approval(boundContext: simulated), context: live))
    }

    @Test("Execution and workflow identities are immutable bindings")
    func testExecutionIdentityMismatch() {
        let bound = context(execution: "EXEC-A", workflow: "WF-A")
        #expect(!accepted(approval(boundContext: bound),
                          context: context(execution: "EXEC-B", workflow: "WF-A")))
        #expect(!accepted(approval(boundContext: bound),
                          context: context(execution: "EXEC-A", workflow: "WF-B")))
    }

    @Test("Stale snapshot, wrong target and wrong tool remain fail-closed")
    func testExistingBindingsRemainEnforced() {
        let bound = context()
        #expect(!accepted(approval(boundContext: bound), context: bound,
                          observation: observation(snapshot: "new-snapshot")))
        #expect(!accepted(approval(boundContext: bound), context: bound,
                          observation: observation(includeTarget: false)))
        #expect(!accepted(approval(boundContext: bound, tool: "type_text"), context: bound))
    }

    @Test("ToolRegistry rejects arguments other than the authorized arguments")
    func testWrongArgumentsRejectedAtRegistry() async {
        let bound = context(mode: .simulation)
        let request = approval(boundContext: bound)
        guard case .authorized(let proof) = DispatchAuthorizer().authorize(
            approval: request, step: step, observation: observation(), context: bound, now: now
        ) else { Issue.record("expected proof"); return }
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"),
                                    simulatorDestinationID: "DEVICE-A", driver: SimulatedDriver())
        let wrong = ToolCall(id: "wrong", name: "tap_element",
                             arguments: ["snapshotID": "snap", "elementID": "other"])
        await #expect(throws: ToolRegistryError.self) {
            try await registry.execute(wrong, authorization: proof)
        }
    }
}

private extension AuthorizationContextBindingTests {
    func approval(boundContext: AuthorizationContext, tool: String = "tap_element") -> HITLApprovalRequest {
        approval(context: boundContext, tool: tool)
    }
}
