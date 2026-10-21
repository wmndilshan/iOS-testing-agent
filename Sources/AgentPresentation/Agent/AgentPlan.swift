import Foundation
import AgentCore

/// The workflow of one turn as a checklist: one step per specialist in the flow, with where each one stands. It is derived from what the agents
/// have done so far, so it needs no extra events and is right after a relaunch too.
public struct AgentPlan: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case pending, working, waitingForApproval, done, issues, skipped

        public var isComplete: Bool { self == .done || self == .issues }
    }

    public struct Step: Identifiable, Sendable, Equatable {
        public var id: String { agent }
        public let agent: String
        public let summary: String
        public let state: State
        public let seconds: Int?
        public let toolCalls: Int
        /// The section that holds this step's work, to jump to it.
        public let sectionID: UUID?
    }

    public let id: UUID
    public let steps: [Step]
    public let isFinished: Bool

    public var completedCount: Int { steps.filter { $0.state.isComplete }.count }
    public var seconds: Int { steps.compactMap(\.seconds).reduce(0, +) }

    public static func build(id: UUID, sections: [AgentSection], flow: AgentFlow, isBusy: Bool, awaitingApproval: Bool) -> AgentPlan {
        let steps = flow.enabledRoles.map { role -> Step in
            let mine = sections.filter { $0.agent == role.rawValue }
            let state: State
            if let live = mine.first(where: \.isActive) {
                state = role == .runner && awaitingApproval ? .waitingForApproval : .working
                _ = live
            } else if let last = mine.last {
                state = last.failedToolCount > 0 ? .issues : .done
            } else {
                state = isBusy ? .pending : .skipped
            }
            let closed = mine.compactMap(\.seconds)
            return Step(agent: role.rawValue, summary: role.summary, state: state, seconds: closed.isEmpty ? nil : closed.reduce(0, +),
                        toolCalls: mine.map(\.toolCount).reduce(0, +), sectionID: mine.last?.id)
        }
        return AgentPlan(id: id, steps: steps, isFinished: !isBusy)
    }

    /// A stable id for a plan that differs from its turn's own message id, so a list can hold both.
    static func planID(for message: UUID) -> UUID {
        var bytes = message.uuid
        bytes.0 ^= 0xFF
        return UUID(uuid: bytes)
    }
}

/// Follow-up messages offered under a verdict, as one-click replies.
public enum AgentSuggestions {
    public static func afterVerdict(_ verdict: String) -> [String] {
        switch verdict.uppercased() {
        case "PASS": return ["Write another case for a related flow", "Run the case again"]
        case "FAIL": return ["Fix the case and run it again", "Explain why it failed"]
        case "INCOMPLETE": return ["Continue", "Retry the run"]
        default: return []
        }
    }
}
