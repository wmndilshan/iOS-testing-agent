import Foundation
import AgentCore

/// One line of what the agents did for a goal, in words: "Tapped “Search”", "Read the screen", "Checked: the title reads Settings".
public struct OperateActivityLine: Identifiable, Equatable, Sendable {
    public enum Outcome: Sendable { case running, ok, failed, passed, notPassed, info }
    public let id: UUID
    public let symbol: String
    public let text: String
    public let agent: String
    public let outcome: Outcome
    public let milliseconds: Int?
}

/// A goal of the plan with everything done for it. The Operate view draws these; it never sees raw tool arguments.
public struct OperateGoalCard: Identifiable, Equatable, Sendable {
    public let id: Int
    public let goal: OperateGoal?
    public let lines: [OperateActivityLine]
    /// What the agents reasoned, quiet and collapsed by default.
    public let reasoning: String
    /// The last check's or finding's sentence.
    public let evidence: String
    public let evidencePassed: Bool?

    /// Number 0 holds what happened before there was a plan.
    public var title: String { goal?.text ?? "Getting ready" }
}

/// Builds the cards from the plan and the reported entries. Pure.
public enum OperateCards {
    public static func build(goals: [OperateGoal], entries: [OperateEntry]) -> [OperateGoalCard] {
        let numbers = Set(goals.map(\.number))
        var cards: [OperateGoalCard] = []
        let prep = entries.filter { !numbers.contains($0.goal) }
        let prepLines = lines(prep)
        if !prepLines.isEmpty { cards.append(card(0, nil, prep)) }
        for goal in goals { cards.append(card(goal.number, goal, entries.filter { $0.goal == goal.number })) }
        return cards
    }

    private static func card(_ number: Int, _ goal: OperateGoal?, _ entries: [OperateEntry]) -> OperateGoalCard {
        let made = lines(entries)
        let judged = made.last { $0.outcome == .passed || $0.outcome == .notPassed }
        let thoughts = entries.filter { $0.kind == .thought }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return OperateGoalCard(id: number, goal: goal, lines: made,
                               reasoning: thoughts.joined(separator: "\n\n"), evidence: judged?.text ?? "", evidencePassed: judged.map { $0.outcome == .passed })
    }

    /// Plumbing never reaches the person: plan payloads, replies like "Verdict recorded.", budget notices.
    public static func lines(_ entries: [OperateEntry]) -> [OperateActivityLine] { entries.compactMap(line(for:)) }

    /// The readable line for one entry, or nil when it is plumbing.
    public static func line(for entry: OperateEntry) -> OperateActivityLine? {
        switch entry.kind {
        case .node: return entry.agent == "replan" ? line(entry, "arrow.triangle.2.circlepath", entry.text, .info) : nil
        case .error: return line(entry, "exclamationmark.octagon", entry.text, .failed)
        case .notice: return line(entry, "info.circle", entry.text, .info)
        case .thought, .text: return nil
        case .tool: return tool(entry)
        }
    }

    private static func line(_ entry: OperateEntry, _ symbol: String, _ text: String, _ outcome: OperateActivityLine.Outcome) -> OperateActivityLine {
        OperateActivityLine(id: entry.id, symbol: symbol, text: text, agent: entry.agent, outcome: outcome, milliseconds: entry.milliseconds)
    }

    private static func tool(_ entry: OperateEntry) -> OperateActivityLine? {
        let args = arguments(entry.args)
        let running = entry.succeeded == nil
        switch entry.text {
        case "set_plan": return nil
        case "report_verdict":
            let passed = (args["passed"] as? Bool) ?? ((args["passed"] as? String)?.lowercased() == "true")
            return line(entry, passed ? "checkmark.seal" : "xmark.seal", (args["evidence"] as? String) ?? "", passed ? .passed : .notPassed)
        case "report_finding": return line(entry, "text.magnifyingglass", (args["answer"] as? String) ?? "", .passed)
        case "report_blocked": return line(entry, "hand.raised", "Needs you: " + ((args["reason"] as? String) ?? ""), .info)
        default: break
        }
        guard let name = args["command"] as? String, let kind = DeviceCommandKind(rawValue: name) else { return nil }
        var arguments: [String: DeviceValue] = [:]
        for (key, value) in args where key != "command" {
            if let text = value as? String { arguments[key] = .string(text) }
            else if let number = value as? Double { arguments[key] = .number(number) }
            else if let flag = value as? Bool { arguments[key] = .bool(flag) }
        }
        let command = DeviceCommand(kind, arguments)
        let outcome: OperateActivityLine.Outcome = running ? .running : (entry.succeeded == true && !entry.summary.hasPrefix("FAILED") ? .ok : .failed)
        return line(entry, symbol(for: kind), describe(command, summary: entry.summary, finished: !running), outcome)
    }

    /// "Tapped “Search”" when the result named the element (a #number or a label alone says little), else the command in words.
    static func describe(_ command: DeviceCommand, summary: String, finished: Bool) -> String {
        switch command.kind {
        case .readScreen: return "Read the screen"
        case .describeScreen: return "Read the screen in full"
        case .find: return "Looked for “\(command.string("text") ?? "")”"
        case .look: return "Looked at the picture: \(command.string("question") ?? "")"
        case .tap, .doubleTap, .longPress:
            if finished, let label = quoted(summary) { return "\(verb(command.kind)) “\(label)”" }
            if let label = command.string("label") { return "\(verb(command.kind)) “\(label)”" }
            return DeviceCommandCatalog.phrase(command)
        case .swipe:
            let dy = (command.number("y2") ?? 0) - (command.number("y1") ?? 0), dx = (command.number("x2") ?? 0) - (command.number("x1") ?? 0)
            return abs(dy) >= abs(dx) ? (dy < 0 ? "Swiped up" : "Swiped down") : (dx < 0 ? "Swiped left" : "Swiped right")
        default: return DeviceCommandCatalog.phrase(command)
        }
    }

    private static func verb(_ kind: DeviceCommandKind) -> String { kind == .tap ? "Tapped" : kind == .doubleTap ? "Double-tapped" : "Pressed and held" }

    private static func quoted(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "“"), let close = text[text.index(after: open)...].firstIndex(of: "”") else { return nil }
        let label = String(text[text.index(after: open)..<close])
        return label.isEmpty ? nil : label
    }

    static func symbol(for kind: DeviceCommandKind) -> String {
        switch kind {
        case .tap, .doubleTap, .longPress: "hand.tap"
        case .swipe, .scroll: "arrow.up.and.down"
        case .typeText, .pressKey: "keyboard"
        case .readScreen, .describeScreen, .find: "list.bullet.rectangle"
        case .look: "eye"
        case .launchApp, .openURL, .terminateApp: "arrow.up.forward.app"
        case .setAppearance: "circle.lefthalf.filled"
        case .pressButton: "button.programmable"
        default: "gearshape"
        }
    }

    private static func arguments(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}
