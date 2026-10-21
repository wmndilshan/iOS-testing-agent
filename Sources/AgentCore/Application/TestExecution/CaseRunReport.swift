import Foundation

/// Where a run's time went: seconds per step, split into the phases that make up a step. Optional in a report, so older reports still read.
public struct RunTiming: Codable, Sendable, Equatable {
    public struct StepTime: Codable, Sendable, Equatable {
        public var seconds: Double
        /// Seconds by phase name: plan, settle, judge, check, replay; whatever is left of `seconds` is "other".
        public var phases: [String: Double]

        public init(seconds: Double, phases: [String: Double]) {
            self.seconds = seconds
            self.phases = phases
        }
    }

    /// Keyed by step number as text (JSON objects have text keys).
    public var steps: [String: StepTime] = [:]

    public init(steps: [String: StepTime] = [:]) { self.steps = steps }

    public var totalSeconds: Double { steps.values.map(\.seconds).reduce(0, +) }

    /// Seconds per phase over the whole run, with the unaccounted rest as "other".
    public var totals: [String: Double] {
        var sums: [String: Double] = [:]
        for step in steps.values {
            for (phase, seconds) in step.phases { sums[phase, default: 0] += seconds }
            sums["other", default: 0] += max(0, step.seconds - step.phases.values.reduce(0, +))
        }
        return sums
    }
}

/// Per-step outcome of a test case run. Persisted as JSON after every step so a viewer can follow a run live.
public struct CaseRunReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case pending, running, passed, failed, skipped, unsupported
        /// Performed by the human (the password step and the login that follows it), never by the agent.
        case humanCompleted
    }

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let sourceStepNumber: Int
        public let intent: String
        public let action: String
        public var status: Status
        public var detail: String
        /// `HITLApprovalDecisionSource` raw value of the approval that authorized the dispatch, if one was needed.
        public var approvalSource: String?
        public var finishedAt: Date?
        /// Screenshot taken when the step finished, relative to the run's evidence folder.
        public var evidencePath: String?

        public init(id: String, sourceStepNumber: Int, intent: String, action: String,
                    status: Status = .pending, detail: String = "", approvalSource: String? = nil, finishedAt: Date? = nil) {
            self.id = id
            self.sourceStepNumber = sourceStepNumber
            self.intent = intent
            self.action = action
            self.status = status
            self.detail = detail
            self.approvalSource = approvalSource
            self.finishedAt = finishedAt
        }
    }

    /// A step of the case as it was planned, kept so a report alone says what the case was and which steps never ran.
    public struct PlannedStep: Codable, Sendable, Equatable {
        public let number: Int
        public let text: String
        public init(number: Int, text: String) { self.number = number; self.text = text }
    }

    public let testKey: String
    public let title: String
    public let mode: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var steps: [Step]
    public var outcome: String
    /// What a later run needs to continue this one. All optional, so reports written before they existed still read.
    public var bundleID: String?
    public var startStep: Int?
    public var endStep: Int?
    public var plannedSteps: [PlannedStep]?
    /// The first step that failed, set when the run finishes.
    public var failedStep: Int?
    /// Where the time went, filled in as steps finish.
    public var timing: RunTiming?

    public init(testKey: String, title: String, mode: String, startedAt: Date = Date(), steps: [Step], outcome: String = "RUNNING") {
        self.testKey = testKey
        self.title = title
        self.mode = mode
        self.startedAt = startedAt
        self.steps = steps
        self.outcome = outcome
    }

    public func count(_ status: Status) -> Int { steps.filter { $0.status == status }.count }

    public mutating func attachEvidence(_ id: String, path: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].evidencePath = path
    }

    public mutating func update(_ id: String, status: Status, detail: String, approvalSource: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].status = status
        steps[index].detail = detail
        steps[index].approvalSource = approvalSource
        steps[index].finishedAt = Date()
    }

    /// Adds a skipped row for each planned step in `range` that has no row at all, so a run that stopped early still lists the steps it did not reach.
    public mutating func addUnreachedRows(in range: ClosedRange<Int>, reason: String) {
        for planned in plannedSteps ?? [] where range.contains(planned.number) && !steps.contains(where: { $0.sourceStepNumber == planned.number }) {
            steps.append(Step(id: "\(planned.number).unreached", sourceStepNumber: planned.number, intent: planned.text, action: "unreached",
                              status: .skipped, detail: reason, finishedAt: Date()))
        }
    }

    /// The lowest step number with a failed row.
    public var firstFailedStep: Int? { steps.filter { $0.status == .failed }.map(\.sourceStepNumber).min() }

    /// Marks every step that was never reached (for example the branch arm that was not selected) as skipped.
    public mutating func closeOut(outcome: String) {
        for index in steps.indices where steps[index].status == .pending || steps[index].status == .running {
            steps[index].status = .skipped
            steps[index].detail = "not reached"
        }
        self.outcome = outcome
        finishedAt = Date()
    }
}
