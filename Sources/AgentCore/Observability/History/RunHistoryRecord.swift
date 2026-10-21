import Foundation

/// One persisted summary line per run. Contains no secrets: only identifiers, counts, labels and
/// redacted text. The full step-by-step trace is stored separately as a `RunTrace`.
public struct RunHistoryRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String { runID }
    public let runID: String
    public let date: Date
    public let scenarioID: String
    public let appBundleID: String?
    /// LIVE_HUMAN_APPROVAL, LIVE_SUPERVISED, NON_LIVE_TEST, CI_AUTOMATED, APP_UI, ...
    public let executionMode: String?
    /// COMPLETED, FAILED, BLOCKED, CANCELLED or INTERRUPTED.
    public let result: String
    public let durationSeconds: Double
    public let stepCount: Int
    public let recoveryCount: Int
    public let healingCount: Int
    public let skillsReused: [String]
    public let skillsCreated: [String]
    public let verificationResult: String
    /// True only when the run's approvals were genuinely given by a human.
    public let humanApproved: Bool

    public init(
        runID: String, date: Date, scenarioID: String, appBundleID: String?, executionMode: String?,
        result: String, durationSeconds: Double, stepCount: Int, recoveryCount: Int, healingCount: Int,
        skillsReused: [String], skillsCreated: [String], verificationResult: String, humanApproved: Bool
    ) {
        self.runID = runID
        self.date = date
        self.scenarioID = scenarioID
        self.appBundleID = appBundleID
        self.executionMode = executionMode
        self.result = SecretRedactor.redact(result)
        self.durationSeconds = durationSeconds
        self.stepCount = stepCount
        self.recoveryCount = recoveryCount
        self.healingCount = healingCount
        self.skillsReused = skillsReused
        self.skillsCreated = skillsCreated
        self.verificationResult = SecretRedactor.redact(verificationResult)
        self.humanApproved = humanApproved
    }

    /// Builds the summary strictly from the recorded trace (no separate bookkeeping to drift).
    public static func make(from trace: RunTrace, result: String? = nil, humanApproved: Bool, executionMode fallbackMode: String? = nil) -> RunHistoryRecord {
        let events = trace.events
        let executed = events.filter { $0.eventType == .executionFinished || $0.eventType == .stepExecuted }
        let reused = Array(Set(events.filter { $0.eventType == .skillSelected }.compactMap { $0.skillID })).sorted()
        let created = Array(Set(events.filter { $0.eventType == .skillLearned }.compactMap { $0.skillID })).sorted()
        let healing = events.filter { $0.eventType == .healed }.count
        let lastVerification = events.last(where: { $0.eventType == .verificationPassed || $0.eventType == .verificationFailed })
        let derivedResult: String
        if let result { derivedResult = result }
        else if events.contains(where: { $0.eventType == .scenarioCompleted }) { derivedResult = "COMPLETED" }
        else if events.contains(where: { $0.eventType == .scenarioCancelled }) { derivedResult = "CANCELLED" }
        else if events.contains(where: { $0.eventType == .budgetExceeded }) { derivedResult = "BLOCKED" }
        else { derivedResult = "FAILED" }
        return RunHistoryRecord(
            runID: trace.runID,
            date: trace.startedAt ?? events.first?.timestamp ?? Date(),
            scenarioID: trace.scenarioID,
            appBundleID: trace.appIdentity?.bundleID,
            executionMode: trace.executionMode ?? fallbackMode,
            result: derivedResult,
            durationSeconds: trace.durationSeconds ?? 0,
            stepCount: executed.count,
            recoveryCount: trace.recoveryEventCount,
            healingCount: healing,
            skillsReused: reused,
            skillsCreated: created,
            verificationResult: lastVerification.map { "\($0.eventType == .verificationPassed ? "VERIFIED" : "NOT VERIFIED"): \($0.result)" } ?? "NONE",
            humanApproved: humanApproved
        )
    }
}

// MARK: - ReplayRequest
