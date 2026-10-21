import Foundation

/// Everything a performer needs. Performers receive the driver *port* and nothing that can authorize.
struct IOSExecutionEnvironment: Sendable {
    let driver: any DeviceDriver
    let artifactStore: (any ArtifactStoring)?
    let association: ArtifactAssociation
    let bundleID: String
    let clock: any ClockProtocol
    let logger: any AppLogger
    let context: LogContext
}

/// What a performer produced, before it is stamped into an `IOSActionResult` / `ToolResult`.
struct IOSActionOutput: Sendable {
    var summary: String
    var status: ToolStatus = .success
    var payload: [String: AnyCodableValue]? = nil
    var observation: Observation? = nil
    var evidence: [ArtifactReference] = []
    var diagnostics: [String: String] = [:]

    init(summary: String, status: ToolStatus = .success, payload: [String: AnyCodableValue]? = nil,
         observation: Observation? = nil, evidence: [ArtifactReference] = [], diagnostics: [String: String] = [:]) {
        self.summary = summary; self.status = status; self.payload = payload
        self.observation = observation; self.evidence = evidence; self.diagnostics = diagnostics
    }

    /// Wraps a driver `ToolResult` unchanged.
    init(_ result: ToolResult) {
        self.init(summary: result.summary, status: result.status, payload: result.payload, observation: result.observation)
    }
}

/// One capability's behavior. Conformances live in `iOS/Performers/`, next to nothing else: adding a
/// capability adds a typed action, one performer and one descriptor, not a case in a large switch.
protocol IOSPerformable: Sendable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput
}

/// The single, bounded polling primitive for waits. It never sleeps outside the injected clock and
/// always terminates: the number of polls is capped regardless of the timeout.
struct ConditionWaiter: Sendable {
    static let minimumPollInterval = 0.05
    static let maximumPolls = 30

    let clock: any ClockProtocol

    /// Evaluates `condition` until it is true or the budget is spent. Returns the number of polls used.
    func wait(timeout: Double, pollInterval: Double, condition: () async throws -> Bool) async throws -> (satisfied: Bool, polls: Int) {
        let interval = max(pollInterval, Self.minimumPollInterval)
        let polls = min(Int((timeout / interval).rounded(.up)) + 1, Self.maximumPolls)
        var remaining = timeout
        for poll in 1...polls {
            if try await condition() { return (true, poll) }
            guard poll < polls, remaining > 0 else { break }
            let pause = min(interval, remaining)
            try await clock.sleep(seconds: pause)
            remaining -= pause
        }
        return (false, polls)
    }
}
