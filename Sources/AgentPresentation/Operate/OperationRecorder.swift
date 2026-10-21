import Foundation
import AgentCore

/// One thing done to the device during an Operate session, in the words a test step would use.
public struct RecordedAction: Equatable, Sendable, Codable {
    public let goal: Int?
    public let text: String
    public let byPerson: Bool
}

/// Turns what an Operate session did into a test case. Pure: it takes the recorded actions and the plan and returns plain-language steps the
/// case runner can plan from. The case names real labels (“Search”), never coordinates.
public enum OperationRecorder {
    public static func action(for execution: DeviceExecution, goal: Int?) -> RecordedAction? {
        guard execution.ok else { return nil }
        return RecordedAction(goal: goal, text: wording(for: execution), byPerson: execution.byPerson)
    }

    /// A tap names the element it hit (taken from the result, which resolved the label), not the point it landed on.
    static func wording(for execution: DeviceExecution) -> String {
        switch execution.command.kind {
        case .tap, .doubleTap, .longPress:
            let verb = execution.command.kind == .tap ? "Tap" : execution.command.kind == .doubleTap ? "Double-tap" : "Press and hold"
            if let label = quoted(in: execution.resultText) { return "\(verb) “\(label)”" }
            if let label = execution.command.string("label") { return "\(verb) “\(label)”" }
            return execution.byPerson ? "\(verb) the element the person pointed at" : DeviceCommandCatalog.phrase(execution.command)
        case .swipe:
            // A swipe is recorded by its direction, not its coordinates.
            let dx = (execution.command.number("x2") ?? 0) - (execution.command.number("x1") ?? 0)
            let dy = (execution.command.number("y2") ?? 0) - (execution.command.number("y1") ?? 0)
            return abs(dy) >= abs(dx) ? (dy < 0 ? "Swipe up" : "Swipe down") : (dx < 0 ? "Swipe left" : "Swipe right")
        default:
            return DeviceCommandCatalog.phrase(execution.command)
        }
    }

    private static func quoted(in text: String) -> String? {
        guard let open = text.firstIndex(of: "“"), let close = text[text.index(after: open)...].firstIndex(of: "”") else { return nil }
        let label = String(text[text.index(after: open)..<close])
        return label.isEmpty ? nil : label
    }

    /// One step per goal that had actions (the goal is the step's text, the concrete actions its data, the check its expected result), then
    /// any action done outside a goal as steps of its own.
    public static func steps(goals: [OperateGoal], actions: [RecordedAction]) -> [TestStepDraft] {
        var steps: [TestStepDraft] = []
        for goal in goals where goal.state == .done {
            let mine = actions.filter { $0.goal == goal.number }
            guard !mine.isEmpty || goal.kind == "verify" || goal.kind == "inspect" else { continue }
            steps.append(TestStepDraft(action: goal.text, data: mine.map(\.text).joined(separator: "; "), expected: goal.expected))
        }
        let known = Set(goals.map(\.number))
        for loose in actions where loose.goal.map({ !known.contains($0) }) ?? true {
            steps.append(TestStepDraft(action: loose.text, data: "", expected: ""))
        }
        return steps
    }

    public static func title(for task: String) -> String {
        let line = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 80 ? trimmed : String(trimmed.prefix(77)) + "…"
    }
}
