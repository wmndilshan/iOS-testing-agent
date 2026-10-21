import Foundation

/// Immutable identity of one permitted dispatch. It contains no credentials or executable input.
public struct AuthorizationContext: Sendable, Equatable {
    public let bundleID: String
    public let simulatorUDID: String
    public let executionMode: ExecutionMode
    public let executionID: String
    public let workflowExecutionID: String?
    public let previewSession: PreviewSessionIdentity?

    public init(bundleID: String, simulatorUDID: String, executionMode: ExecutionMode,
                executionID: String, workflowExecutionID: String? = nil,
                previewSession: PreviewSessionIdentity? = nil) {
        self.bundleID = bundleID
        self.simulatorUDID = simulatorUDID
        self.executionMode = executionMode
        self.executionID = executionID
        self.workflowExecutionID = workflowExecutionID
        self.previewSession = previewSession
    }
}
