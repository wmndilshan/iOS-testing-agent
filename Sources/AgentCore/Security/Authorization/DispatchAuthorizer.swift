import Foundation

/// The trusted, pure pre-dispatch check: may this approved request be executed right now?
///
/// It re-validates everything a human approval could have gone stale on (TTL, denial, status,
/// tool identity, target element identity, snapshot freshness) against the CURRENT observation,
/// closing the time-of-check/time-of-use gap between approval and execution. It has no side
/// effects and no access to any executor: the caller applies the verdict.
public struct DispatchAuthorizer: Sendable {

    public struct Rejection: Sendable, Equatable {
        /// New approval status, or `nil` when the existing status must be left unchanged.
        public let newStatus: HITLApprovalStatus?
        public let blockedReason: String?
        public let error: DriverError
    }

    /// Proof that `authorize` accepted a request. Only `DispatchAuthorizer` can create one
    /// (file-private initializer); `ScenarioStepDispatcher.execute` requires it.
    public struct Authorized: Sendable {
        public let observation: Observation
        /// The element the approval resolved to in the current observation, if it named one.
        public let target: UIElementSnapshot?
        /// Exactly what was authorized: the tool, its arguments, and the approval they came from.
        /// `ToolRegistry.execute` runs a call only if it matches these.
        public let toolName: String
        public let arguments: [String: AnyCodableValue]
        public let approvalID: UUID
        public let context: AuthorizationContext
        let approvalGrant: HITLApprovalGrant

        fileprivate init(observation: Observation, target: UIElementSnapshot?, toolName: String,
                         arguments: [String: AnyCodableValue], approvalID: UUID,
                         context: AuthorizationContext, approvalGrant: HITLApprovalGrant) {
            self.observation = observation
            self.target = target
            self.toolName = toolName
            self.arguments = arguments
            self.approvalID = approvalID
            self.context = context
            self.approvalGrant = approvalGrant
        }
    }

    public enum Decision: Sendable {
        case authorized(Authorized)
        case rejected(Rejection)
    }

    public init() {}

    public func authorize(
        approval: HITLApprovalRequest,
        step: ScenarioStep,
        observation: Observation?,
        context: AuthorizationContext,
        now: Date
    ) -> Decision {
        if now >= approval.expiresAt || approval.status == .expired {
            let reason = ApprovalPolicy.expiredMessage
            return .rejected(Rejection(newStatus: .expired, blockedReason: reason, error: .actionFailed(reason)))
        }

        if approval.status == .denied {
            return .rejected(Rejection(newStatus: nil, blockedReason: nil, error: .actionFailed("Action was denied by supervisor.")))
        }

        guard approval.status == .approved else {
            let reason = "Action requires explicit approval before execution (current status: \(approval.status.rawValue))."
            return .rejected(Rejection(newStatus: .failed, blockedReason: reason, error: .actionFailed(reason)))
        }

        guard let grant = approval.authorizationGrant, grant.approvalID == approval.id,
              grant.fingerprint == approval.fingerprint else {
            let reason = "Approved state has no matching authority grant."
            return .rejected(Rejection(newStatus: .failed, blockedReason: reason, error: .actionFailed(reason)))
        }

        guard let obs = observation else {
            return .rejected(Rejection(newStatus: .failed, blockedReason: nil, error: .actionFailed("No active observation available.")))
        }

        let contextMismatch: String?
        if grant.context.bundleID != context.bundleID { contextMismatch = "bundle" }
        else if grant.context.simulatorUDID != context.simulatorUDID { contextMismatch = "simulator" }
        else if grant.context.executionMode != context.executionMode { contextMismatch = "execution mode" }
        else if grant.context.executionID != context.executionID { contextMismatch = "execution ID" }
        else if grant.context.workflowExecutionID != context.workflowExecutionID { contextMismatch = "workflow execution" }
        else if grant.context.previewSession != context.previewSession { contextMismatch = "Preview session" }
        else { contextMismatch = nil }
        if let contextMismatch {
            let reason = "Dispatch \(contextMismatch) does not match the authority-approved context."
            return .rejected(Rejection(newStatus: .failed, blockedReason: reason, error: .actionFailed(reason)))
        }
        guard approval.targetApp == obs.bundleID, obs.bundleID == context.bundleID else {
            let reason = "Application binding mismatch: approval, observation, and dispatch bundle must match."
            return .rejected(Rejection(newStatus: .failed, blockedReason: reason, error: .actionFailed(reason)))
        }
        if let observedUDID = obs.simulatorUDID, observedUDID != context.simulatorUDID {
            let reason = "Simulator binding mismatch: observation device differs from approved dispatch device."
            return .rejected(Rejection(newStatus: .failed, blockedReason: reason, error: .actionFailed(reason)))
        }

        // 1. Tool identity: the approved tool must be the scenario step's own tool.
        if let approvedTool = approval.toolName, approvedTool != step.toolName {
            let reason = "Action tool mismatch! Approved tool '\(approvedTool)' differs from scenario step tool '\(step.toolName)'."
            return .rejected(Rejection(newStatus: .failed, blockedReason: reason, error: .actionFailed(reason)))
        }
        // 2. Target element identity in the CURRENT snapshot (TOCTOU hardening).
        var target: UIElementSnapshot? = nil
        if let targetLoc = approval.targetLocator {
            guard let resolved = obs.elements.first(where: { $0.id == targetLoc.elementID }) else {
                let reason = "Target element mismatch: locator target '\(targetLoc.elementID)' is missing from active snapshot."
                return .rejected(Rejection(newStatus: .failed, blockedReason: reason, error: .elementNotFound(targetLoc.elementID)))
            }
            guard resolved.role.lowercased() == targetLoc.role.lowercased() else {
                let reason = "Target element mismatch: Element '\(targetLoc.elementID)' role changed from '\(targetLoc.role)' to '\(resolved.role)'."
                return .rejected(Rejection(
                    newStatus: .failed, blockedReason: reason,
                    error: .typeMismatch(expected: targetLoc.role, actual: resolved.role, elementID: targetLoc.elementID)
                ))
            }
            if let expectedIdentifier = targetLoc.identifier, !expectedIdentifier.isEmpty {
                let actualIdentifier = resolved.identifier ?? ""
                let actualLabel = resolved.label ?? ""
                guard actualIdentifier == expectedIdentifier || actualLabel == expectedIdentifier else {
                    let reason = "Target element mismatch: Element '\(targetLoc.elementID)' identifier changed from '\(expectedIdentifier)' to '\(actualIdentifier)'."
                    return .rejected(Rejection(newStatus: .failed, blockedReason: reason, error: .actionFailed(reason)))
                }
            }
            target = resolved
        }

        // 3. Snapshot freshness: the approval is bound to exactly one snapshot.
        if let approvedSnapshot = approval.snapshotID, approvedSnapshot != obs.snapshotID {
            let reason = "Stale snapshot! Approved snapshot was '\(approvedSnapshot)', active snapshot is '\(obs.snapshotID)'."
            return .rejected(Rejection(
                newStatus: .failed, blockedReason: reason,
                error: .staleSnapshot(requested: approvedSnapshot, current: obs.snapshotID)
            ))
        }

        return .authorized(Authorized(
            observation: obs, target: target, toolName: step.toolName,
            arguments: approval.arguments, approvalID: approval.id, context: context,
            approvalGrant: grant
        ))
    }
}
