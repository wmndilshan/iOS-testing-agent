import Foundation

/// The only code that calls `ToolRegistry.execute` for a scenario step, and the only code that
/// takes the post-action observation.
///
/// It carries out an authorization; it never makes one. `execute` requires a
/// `DispatchAuthorizer.Authorized` value, which only `DispatchAuthorizer` can create (its
/// initializer is file-private), so a dispatch that skipped TTL, denial, tool-identity, target and
/// snapshot checks does not type-check. Approval status, tracing and lifecycle transitions stay in
/// `ScenarioExecutionController`, which sequences: authorize → consume token → execute → observe →
/// verify.
struct ScenarioStepDispatcher {

    /// Turns the human-approved step into the tool call that is executed.
    func toolCall(for step: ScenarioStep, approval: HITLApprovalRequest) -> ToolCall {
        ToolCall(id: UUID().uuidString, name: step.toolName, arguments: approval.arguments)
    }

    /// Enables or disables live execution on drivers that support the toggle. Runs before dispatch.
    func configureLiveMode(driver: any DeviceDriver, enabled: Bool) async {
        if let switchable = driver as? any LiveExecutionControllable {
            await switchable.setLiveExecution(enabled: enabled)
        }
    }

    /// Executes an authorized tool call. Throws whatever the driver throws.
    func execute(
        _ toolCall: ToolCall,
        authorization: DispatchAuthorizer.Authorized,
        toolRegistry: ToolRegistry,
        association: ArtifactAssociation = ArtifactAssociation()
    ) async throws -> ToolResult {
        try await toolRegistry.execute(toolCall, authorization: authorization, association: association)
    }

    /// Fresh observation after an action. Verification must use this, never the pre-action snapshot.
    func captureFreshObservation(driver: any DeviceDriver, bundleID: String) async throws -> Observation {
        try await driver.captureObservation(bundleID: bundleID)
    }
}
