import Foundation

/// Diagnostics logged for each closed-loop cycle without recording sensitive data.
public struct ClosedLoopDiagnostics: Codable, Sendable, Identifiable {
    public var id: String {
        [runID ?? "no-run", executionID ?? "no-execution", stepID, snapshotID].joined(separator: "_")
    }
    /// The active `RunTrace.runID`. `nil` means no run existed when the diagnostic was recorded.
    public let runID: String?
    public let scenarioID: String
    public let stepID: String
    public let snapshotID: String
    public let currentStepIndex: Int
    public let fingerprint: String?
    public let approvalID: String?
    /// The trusted dispatch correlation identifier, distinct from the XCTest runner invocation.
    public let executionID: String?
    /// The XCTest runner/result-bundle identifier when directly available; otherwise `nil`.
    public let runnerID: String?
    public let driverInvoked: Bool
    public let driverSucceeded: Bool
    public let postObservationSnapshotID: String?
    public let scenarioVerified: Bool
    public let progressDetected: Bool
    public let failureReason: String?
    public let verificationResult: String?
    public let transition: String?
    public let cancellationReason: String?
    public let timestamp: Date

    public init(
        runID: String?,
        scenarioID: String,
        stepID: String,
        snapshotID: String,
        currentStepIndex: Int = 0,
        fingerprint: String? = nil,
        approvalID: String? = nil,
        executionID: String? = nil,
        runnerID: String? = nil,
        driverInvoked: Bool,
        driverSucceeded: Bool,
        postObservationSnapshotID: String? = nil,
        scenarioVerified: Bool,
        progressDetected: Bool,
        failureReason: String? = nil,
        verificationResult: String? = nil,
        transition: String? = nil,
        cancellationReason: String? = nil,
        timestamp: Date = Date()
    ) {
        self.runID = runID
        self.scenarioID = scenarioID
        self.stepID = stepID
        self.snapshotID = snapshotID
        self.currentStepIndex = currentStepIndex
        self.fingerprint = fingerprint
        self.approvalID = approvalID
        self.executionID = executionID
        self.runnerID = runnerID
        self.driverInvoked = driverInvoked
        self.driverSucceeded = driverSucceeded
        self.postObservationSnapshotID = postObservationSnapshotID
        self.scenarioVerified = scenarioVerified
        self.progressDetected = progressDetected
        self.failureReason = failureReason
        self.verificationResult = verificationResult
        self.transition = transition
        self.cancellationReason = cancellationReason
        self.timestamp = timestamp
    }
}
