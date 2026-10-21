import Foundation

public enum ScenarioPhase: String, Codable, Sendable, CaseIterable {
    case ready = "Ready"
    case actionProposed = "Action Proposed"
    case actionApproved = "Action Approved"
    case actionExecuting = "Action Executing"
    case actionSucceeded = "Action Succeeded"
    case actionFailed = "Action Failed"
    case teardownProposed = "Teardown Proposed"
    case teardownApproved = "Teardown Approved"
    case teardownExecuting = "Teardown Executing"
    case restored = "Restored"
    case restorationFailed = "Restoration Failed"

    public var isTerminal: Bool {
        self == .restored || self == .restorationFailed || self == .actionFailed
    }

}
