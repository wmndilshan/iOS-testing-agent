import Foundation

/// Structured audit trail for one scenario run.
/// Security Invariant: every free-text field is passed through `SecretRedactor` before it is
/// stored, so credentials, API keys and bearer/JWT values can never enter a trace.
public struct RunTrace: Codable, Sendable, Equatable {
    public let runID: String
    public let scenarioID: String
    public private(set) var events: [RunTraceEvent] = []

    public private(set) var startedAt: Date? = nil
    public private(set) var endedAt: Date? = nil
    public private(set) var appIdentity: AppIdentity? = nil
    public private(set) var simulatorID: String? = nil
    public private(set) var simulatorName: String? = nil
    /// Execution mode label (e.g. LIVE_HUMAN_APPROVAL, CI_AUTOMATED) so a trace can never be
    /// mistaken for evidence of a different mode.
    public private(set) var executionMode: String? = nil

    public init(runID: String = UUID().uuidString, scenarioID: String, startedAt: Date = Date()) {
        self.runID = runID
        self.scenarioID = scenarioID
        self.startedAt = startedAt
    }

    public mutating func setContext(
        appIdentity: AppIdentity? = nil,
        simulatorID: String? = nil,
        simulatorName: String? = nil,
        executionMode: String? = nil
    ) {
        if let appIdentity { self.appIdentity = appIdentity }
        if let simulatorID { self.simulatorID = simulatorID }
        if let simulatorName { self.simulatorName = simulatorName }
        if let executionMode { self.executionMode = executionMode }
    }

    public mutating func finish(at date: Date = Date()) {
        endedAt = date
    }

    public var durationSeconds: Double? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    public mutating func append(
        executionID: String? = nil,
        toolName: String? = nil,
        actionType: String? = nil,
        eventType: RunTraceEventType,
        stepID: String? = nil,
        skillID: String? = nil,
        skillVersion: Int? = nil,
        snapshotID: String? = nil,
        result: String,
        proposalFingerprint: String? = nil,
        tokenID: String? = nil,
        durationSeconds: Double? = nil,
        failureClass: FailureClass? = nil,
        timestamp: Date = Date()
    ) {
        let event = RunTraceEvent(
            runID: runID,
            scenarioID: scenarioID,
            stepID: stepID,
            skillID: skillID,
            skillVersion: skillVersion,
            snapshotID: snapshotID,
            timestamp: timestamp,
            eventType: eventType,
            result: SecretRedactor.redact(result),
            proposalFingerprint: proposalFingerprint,
            tokenID: tokenID,
            durationSeconds: durationSeconds,
            failureClass: failureClass,
            executionID: executionID,
            toolName: toolName,
            actionType: actionType
        )
        events.append(event)
    }

    public func events(forStep stepID: String) -> [RunTraceEvent] {
        events.filter { $0.stepID == stepID }
    }

    public var recoveryEventCount: Int {
        events.filter { $0.eventType == .recoveryDecided || $0.eventType == .recoveryProposalIssued }.count
    }
}
