import Foundation

public struct RecoveryContext: Sendable {
    public let scenario: SafeScenario?
    public let stepIndex: Int
    public let observation: Observation?
    public let failure: FailureClass
    public let detail: String
    /// True when the model has already produced (and had rejected) this exact proposal
    /// fingerprint. Asking again would loop on an invalid action, so it is never allowed.
    public let proposalWasAlreadyRejected: Bool
    public let llmBudgetAvailable: Bool

    public init(
        scenario: SafeScenario? = nil,
        stepIndex: Int = 0,
        observation: Observation? = nil,
        failure: FailureClass,
        detail: String = "",
        proposalWasAlreadyRejected: Bool = false,
        llmBudgetAvailable: Bool = true
    ) {
        self.scenario = scenario
        self.stepIndex = stepIndex
        self.observation = observation
        self.failure = failure
        self.detail = detail
        self.proposalWasAlreadyRejected = proposalWasAlreadyRejected
        self.llmBudgetAvailable = llmBudgetAvailable
    }
}
