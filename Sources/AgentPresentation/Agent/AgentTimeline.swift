import Foundation
import AgentCore

/// One agent's stretch of work, from the moment the orchestrator handed it a task: its reasoning, tool calls and written report.
public struct AgentSection: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var agent: String
    public var task: String
    public var items: [AgentChatMessage]
    public var isActive: Bool
    public var startedAt: Date
    public var endedAt: Date?

    public var toolCount: Int { items.filter { $0.kind == .tool }.count }
    public var failedToolCount: Int { items.filter { $0.kind == .tool && $0.result != nil && !$0.succeeded }.count }
    public var seconds: Int? { endedAt.map { max(0, Int($0.timeIntervalSince(startedAt).rounded())) } }
}

public enum AgentTimelineItem: Identifiable, Sendable, Equatable {
    case message(AgentChatMessage)
    case section(AgentSection)
    /// The workflow of a turn, shown under the person's message.
    case plan(AgentPlan)

    public var id: UUID {
        switch self {
        case .message(let message): return message.id
        case .section(let section): return section.id
        case .plan(let plan): return plan.id
        }
    }
}

/// Turns the flat event log into what the window shows: the person's messages and the orchestrator's answers as a conversation, and each
/// specialist's work as one section. The orchestrator's own `delegate_*` tool calls are left out; the section is that call.
public enum AgentTimeline {
    public static func build(_ messages: [AgentChatMessage], isBusy: Bool, flow: AgentFlow? = nil, awaitingApproval: Bool = false) -> [AgentTimelineItem] {
        var items: [AgentTimelineItem] = []
        var open: AgentSection?
        // Test cases written during a section are shown right after it, so they stay visible when the section is folded.
        var hoisted: [AgentChatMessage] = []

        func close() {
            guard var section = open else { return }
            section.isActive = false
            section.endedAt = section.items.compactMap { $0.endedAt ?? $0.date }.max() ?? section.startedAt
            items.append(.section(section))
            items += hoisted.map { .message($0) }
            hoisted = []
            open = nil
        }

        for message in messages {
            switch message.kind {
            case .handoff:
                close()
                open = AgentSection(id: message.id, agent: message.toolName, task: message.text, items: [], isActive: true, startedAt: message.date)
            case .thinking, .text, .tool:
                if message.kind == .tool, message.toolName.hasPrefix("delegate_") { continue }
                if var section = open, message.agent == section.agent {
                    section.items.append(message)
                    open = section
                } else {
                    close()
                    items.append(.message(message))
                }
            case .testCase:
                if open != nil { hoisted.append(message) } else { items.append(.message(message)) }
            case .user, .verdict, .error, .notice:
                close()
                items.append(.message(message))
            }
        }
        if var section = open {
            section.isActive = isBusy
            section.endedAt = isBusy ? nil : section.items.compactMap { $0.endedAt ?? $0.date }.max()
            items.append(.section(section))
            items += hoisted.map { .message($0) }
        }
        guard let flow else { return items }
        return withPlans(items, flow: flow, isBusy: isBusy, awaitingApproval: awaitingApproval)
    }

    /// Puts each turn's plan right under the message that started it, for turns where the team did something (or is about to).
    private static func withPlans(_ items: [AgentTimelineItem], flow: AgentFlow, isBusy: Bool, awaitingApproval: Bool) -> [AgentTimelineItem] {
        let userIndexes = items.indices.filter { if case .message(let m) = items[$0], m.kind == .user { return true } else { return false } }
        guard !userIndexes.isEmpty else { return items }
        var plans: [Int: AgentPlan] = [:]
        for (n, start) in userIndexes.enumerated() {
            let end = n + 1 < userIndexes.count ? userIndexes[n + 1] : items.count
            let sections = items[start..<end].compactMap { item -> AgentSection? in if case .section(let s) = item { return s } else { return nil } }
            let isLast = n == userIndexes.count - 1
            guard !sections.isEmpty || (isLast && isBusy), case .message(let user) = items[start] else { continue }
            plans[start] = AgentPlan.build(id: AgentPlan.planID(for: user.id), sections: sections, flow: flow, isBusy: isLast && isBusy, awaitingApproval: isLast && awaitingApproval)
        }
        var result: [AgentTimelineItem] = []
        for (index, item) in items.enumerated() {
            result.append(item)
            if let plan = plans[index] { result.append(.plan(plan)) }
        }
        return result
    }
}
