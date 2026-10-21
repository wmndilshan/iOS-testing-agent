import Foundation

/// The only thing "replay" produces: a request to start the same scenario again. It carries no
/// approval, token, proposal or tool call, so a replay can only proceed by being fed to
/// `ScenarioExecutionController.startScenario`, then observing, proposing, validating and being
/// approved like any other run.
public struct ReplayRequest: Equatable, Sendable {
    public init(sourceRunID: String, scenarioID: String) {
        self.sourceRunID = sourceRunID
        self.scenarioID = scenarioID
    }
    public let sourceRunID: String
    public let scenarioID: String
    public let requiresFreshObservation: Bool = true
    public let requiresNewAuthorization: Bool = true
}

// MARK: - RunHistoryStore
