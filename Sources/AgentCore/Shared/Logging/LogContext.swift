import Foundation

/// Correlation identifiers attached to log events. Every field is optional: set what is known.
///
/// Ownership (who generates each ID; no layer invents its own):
/// - `runID`: the `RunTrace` of the active scenario run.
/// - `scenarioID`, `stepID`: `ScenarioCatalog` definitions.
/// - `proposalID`: the proposal fingerprint computed by the trusted domain.
/// - `approvalID`: the `HITLApprovalRequest.id`.
/// - `snapshotID`: the `Observation` the action is bound to.
/// - `executionID`: generated once per dispatch by `ScenarioExecutionController`.
/// - `requestID`: generated once per network request by the network owner (`LLMGateway`).
public struct LogContext: Sendable, Equatable, Codable {
    public var runID: String?
    public var scenarioID: String?
    public var stepID: String?
    public var proposalID: String?
    public var approvalID: String?
    public var snapshotID: String?
    public var executionID: String?
    public var requestID: String?
    public var toolName: String?
    public var elementID: String?

    public init(
        runID: String? = nil, scenarioID: String? = nil, stepID: String? = nil, proposalID: String? = nil,
        approvalID: String? = nil, snapshotID: String? = nil, executionID: String? = nil,
        requestID: String? = nil, toolName: String? = nil, elementID: String? = nil
    ) {
        self.runID = runID; self.scenarioID = scenarioID; self.stepID = stepID; self.proposalID = proposalID
        self.approvalID = approvalID; self.snapshotID = snapshotID; self.executionID = executionID
        self.requestID = requestID; self.toolName = toolName; self.elementID = elementID
    }

    /// Values in `other` win where set.
    public func merged(with other: LogContext) -> LogContext {
        LogContext(
            runID: other.runID ?? runID, scenarioID: other.scenarioID ?? scenarioID, stepID: other.stepID ?? stepID,
            proposalID: other.proposalID ?? proposalID, approvalID: other.approvalID ?? approvalID,
            snapshotID: other.snapshotID ?? snapshotID, executionID: other.executionID ?? executionID,
            requestID: other.requestID ?? requestID, toolName: other.toolName ?? toolName, elementID: other.elementID ?? elementID
        )
    }

    /// Set fields as an ordered key/value list, for formatting.
    public var setFields: [(key: String, value: String)] {
        [("runID", runID), ("scenarioID", scenarioID), ("stepID", stepID), ("proposalID", proposalID),
         ("approvalID", approvalID), ("snapshotID", snapshotID), ("executionID", executionID),
         ("requestID", requestID), ("toolName", toolName), ("elementID", elementID)]
            .compactMap { k, v in v.map { (k, $0) } }
    }
}
