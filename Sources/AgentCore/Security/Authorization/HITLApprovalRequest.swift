import Foundation

public enum HITLApprovalStatus: String, Codable, Sendable, Equatable {
    case pending
    case approved
    case executing
    case succeeded
    case failed
    case expired
    case denied
}

/// The trusted origin of an approval decision. This is audit metadata, not an authorization
/// token; only `HITLApprovalAuthority` can create the opaque grant consumed by the authorizer.
public enum HITLApprovalDecisionSource: String, Codable, Sendable, Equatable {
    case humanUI
    case humanCLI
    case explicitAutomationPolicy
    case testAuthority
}

/// Opaque proof that the approval authority transitioned one exact pending request to approved.
/// Callers may inspect provenance, but cannot construct a grant.
public struct HITLApprovalGrant: Sendable, Equatable {
    public let approvalID: UUID
    public let source: HITLApprovalDecisionSource
    public let decidedAt: Date
    public let fingerprint: TrustedActionFingerprint?
    public let context: AuthorizationContext

    fileprivate init(approvalID: UUID, source: HITLApprovalDecisionSource, decidedAt: Date,
                     fingerprint: TrustedActionFingerprint?, context: AuthorizationContext) {
        self.approvalID = approvalID
        self.source = source
        self.decidedAt = decidedAt
        self.fingerprint = fingerprint
        self.context = context
    }
}

public struct TargetElementLocatorDetails: Codable, Sendable, Equatable {
    public let elementID: String
    public let role: String
    public let identifier: String?
    public let label: String?
    public let frame: ElementFrame?

    public init(
        elementID: String,
        role: String,
        identifier: String? = nil,
        label: String? = nil,
        frame: ElementFrame? = nil
    ) {
        self.elementID = elementID
        self.role = role
        self.identifier = identifier
        self.label = label
        self.frame = frame
    }
}

public struct HITLApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let actionName: String
    public let toolName: String?
    public let boundTestCaseID: String?
    public let reason: String
    public let targetApp: String
    public fileprivate(set) var status: HITLApprovalStatus

    // Exact binding details
    public let snapshotID: String?
    public let arguments: [String: AnyCodableValue]
    public let targetLocator: TargetElementLocatorDetails?

    // Lifecycle & Expiration (120s policy)
    public let createdAt: Date
    public let expiresAt: Date

    // Execution result details if completed/failed
    public var executionSummary: String?
    public var executionError: String?
    public var executedLive: Bool?
    public var driverInvoked: Bool
    public var blockedReason: String?

    /// Present only after the dedicated authority approved this exact request.
    fileprivate var grant: HITLApprovalGrant?

    public init(
        id: UUID = UUID(),
        actionName: String,
        toolName: String? = nil,
        boundTestCaseID: String? = nil,
        reason: String,
        targetApp: String,
        snapshotID: String? = nil,
        arguments: [String: AnyCodableValue] = [:],
        targetLocator: TargetElementLocatorDetails? = nil,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        executionSummary: String? = nil,
        executionError: String? = nil,
        executedLive: Bool? = nil,
        driverInvoked: Bool = false,
        blockedReason: String? = nil
    ) {
        self.id = id
        self.actionName = actionName
        self.toolName = toolName
        self.boundTestCaseID = boundTestCaseID
        self.reason = reason
        self.targetApp = targetApp
        self.snapshotID = snapshotID
        self.arguments = arguments
        self.targetLocator = targetLocator
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(120)
        self.executionSummary = executionSummary
        self.executionError = executionError
        self.executedLive = executedLive
        self.driverInvoked = driverInvoked
        self.blockedReason = blockedReason
        self.status = .pending
        self.grant = nil
    }

    public var isResolved: Bool {
        status != .pending
    }

    public var isApproved: Bool? {
        switch status {
        case .pending: return nil
        case .approved, .executing, .succeeded, .failed: return true
        case .denied, .expired: return false
        }
    }

    public var isConsumed: Bool {
        status == .executing || status == .succeeded || status == .failed
    }

    public var fingerprint: TrustedActionFingerprint? {
        guard let scenarioID = boundTestCaseID,
              let snapID = snapshotID,
              let tool = toolName,
              let elemID = targetLocator?.elementID else {
            return nil
        }
        return TrustedActionFingerprint(
            scenarioID: scenarioID,
            snapshotID: snapID,
            elementID: elemID,
            toolName: tool,
            arguments: arguments
        )
    }

    /// Internal view used by `DispatchAuthorizer`; the value itself remains unconstructible.
    var authorizationGrant: HITLApprovalGrant? { grant }
}

/// The only type permitted to transition trusted approval state.
///
/// It is intentionally module-internal: UI and orchestration request decisions through controller
/// methods, while external AgentCore clients can only construct pending requests and inspect state.
enum HITLApprovalAuthority {
    @discardableResult
    static func approve(_ request: inout HITLApprovalRequest, source: HITLApprovalDecisionSource,
                        context: AuthorizationContext, at now: Date) -> Bool {
        guard request.status == .pending else { return false }
        guard now < request.expiresAt else {
            expire(&request)
            return false
        }
        request.grant = HITLApprovalGrant(approvalID: request.id, source: source,
                                         decidedAt: now, fingerprint: request.fingerprint,
                                         context: context)
        request.status = .approved
        return true
    }

    static func deny(_ request: inout HITLApprovalRequest, reason: String? = nil) {
        guard request.status == .pending || request.status == .approved else { return }
        request.grant = nil
        request.status = .denied
        if let reason { request.blockedReason = reason }
    }

    static func expire(_ request: inout HITLApprovalRequest, reason: String? = nil) {
        request.grant = nil
        request.status = .expired
        if let reason { request.blockedReason = reason }
    }

    @discardableResult
    static func consume(_ request: inout HITLApprovalRequest, grant: HITLApprovalGrant) -> Bool {
        guard request.status == .approved, request.grant == grant,
              grant.approvalID == request.id else { return false }
        request.status = .executing
        return true
    }

    static func succeed(_ request: inout HITLApprovalRequest) {
        guard request.status == .executing else { return }
        request.status = .succeeded
    }

    static func fail(_ request: inout HITLApprovalRequest, reason: String? = nil) {
        guard request.status != .denied && request.status != .expired else { return }
        request.status = .failed
        if let reason { request.blockedReason = reason }
    }
}
