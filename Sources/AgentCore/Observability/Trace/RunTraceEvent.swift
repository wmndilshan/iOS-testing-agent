import Foundation

public enum RunTraceEventType: String, Codable, Sendable, CaseIterable {
    case observed = "OBSERVED"
    case skillLookup = "SKILL_LOOKUP"
    case skillSelected = "SKILL_SELECTED"
    case preconditionsPassed = "PRECONDITIONS_PASSED"
    case stepSkipped = "STEP_SKIPPED"
    case approvalRequested = "APPROVAL_REQUESTED"
    case tokenIssued = "TOKEN_ISSUED"
    case stepExecuted = "STEP_EXECUTED"
    case postObserved = "POST_OBSERVED"
    case verificationPassed = "VERIFICATION_PASSED"
    case verificationFailed = "VERIFICATION_FAILED"
    case healingTriggered = "HEALING_TRIGGERED"
    case healed = "HEALED"
    case skillLearned = "SKILL_LEARNED"
    case skillQuarantined = "SKILL_QUARANTINED"
    case budgetExceeded = "BUDGET_EXCEEDED"
    case scenarioCompleted = "SCENARIO_COMPLETED"
    case scenarioCancelled = "SCENARIO_CANCELLED"

    // Product-layer events: every stage of the trusted spine leaves a trace record.
    case runStarted = "RUN_STARTED"
    case proposalReceived = "PROPOSAL_RECEIVED"
    case proposalValidated = "PROPOSAL_VALIDATED"
    case proposalRejected = "PROPOSAL_REJECTED"
    case approvalGranted = "APPROVAL_GRANTED"
    case approvalDenied = "APPROVAL_DENIED"
    case approvalExpired = "APPROVAL_EXPIRED"
    case executionStarted = "EXECUTION_STARTED"
    case executionFinished = "EXECUTION_FINISHED"
    case failureClassified = "FAILURE_CLASSIFIED"
    case recoveryDecided = "RECOVERY_DECIDED"
    case recoveryProposalIssued = "RECOVERY_PROPOSAL_ISSUED"
    case runResumedAfterRestart = "RUN_RESUMED_AFTER_RESTART"
    case runFinished = "RUN_FINISHED"
}

// MARK: - RunTraceEvent

public struct RunTraceEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let runID: String
    public let scenarioID: String
    public let stepID: String?
    public let skillID: String?
    public let skillVersion: Int?
    public let snapshotID: String?
    public let timestamp: Date
    public let eventType: RunTraceEventType
    public let result: String
    /// Fingerprint of the proposal this event concerns (never the proposal's free text).
    public let proposalFingerprint: String?
    /// Single-use approval token ID (an audit correlation UUID, never an authentication secret).
    public let tokenID: String?
    public let durationSeconds: Double?
    public let failureClass: FailureClass?
    /// Correlates every event of one dispatch: authorization -> dispatch -> tool -> iOS action -> observation -> verification.
    /// An opaque per-dispatch UUID; never derived from content. Absent on records written before this field existed.
    public let executionID: String?
    /// The cataloged tool and its canonical action name (for example `long_press_element` / `ios.long_press`). Names only:
    /// never arguments, text or targets' values.
    public let toolName: String?
    public let actionType: String?

    public init(
        id: UUID = UUID(),
        runID: String,
        scenarioID: String,
        stepID: String? = nil,
        skillID: String? = nil,
        skillVersion: Int? = nil,
        snapshotID: String? = nil,
        timestamp: Date = Date(),
        eventType: RunTraceEventType,
        result: String,
        proposalFingerprint: String? = nil,
        tokenID: String? = nil,
        durationSeconds: Double? = nil,
        failureClass: FailureClass? = nil,
        executionID: String? = nil,
        toolName: String? = nil,
        actionType: String? = nil
    ) {
        self.executionID = executionID
        self.toolName = toolName
        self.actionType = actionType
        self.proposalFingerprint = proposalFingerprint
        self.tokenID = tokenID
        self.durationSeconds = durationSeconds
        self.failureClass = failureClass
        self.id = id
        self.runID = runID
        self.scenarioID = scenarioID
        self.stepID = stepID
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.snapshotID = snapshotID
        self.timestamp = timestamp
        self.eventType = eventType
        self.result = result
    }
}

// MARK: - RunTrace
