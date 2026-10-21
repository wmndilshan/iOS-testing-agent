import Foundation
import AgentCore
import AgentInfrastructure

/// Which actions need a person, and what that person is shown. An action whose wording says it deletes, removes or ends something
/// is never approved by scripted policy.
enum DestructiveActionGate {
    static let words = ["delete", "remove", "trash", "erase", "clear all", "log out", "logout", "sign out", "unsubscribe", "discard"]

    static func isDestructive(_ step: IRStep) -> Bool {
        let text = [step.intent, step.target?.label ?? "", step.target?.identifier ?? ""].joined(separator: " ").lowercased()
        return step.action != .verifyOnly && words.contains { text.contains($0) }
    }

    /// The labels on the same row as the target, so the person approving can see which item an icon belongs to.
    static func rowContext(of step: IRStep, in observation: Observation) -> String {
        guard let target = step.target else { return "unknown" }
        func isTarget(_ element: UIElementSnapshot) -> Bool {
            guard element.role == target.role else { return false }
            if let identifier = target.identifier, !identifier.isEmpty { return element.identifier == identifier }
            return element.label == target.label
        }
        guard let element = observation.elements.first(where: isTarget), let frame = element.frame else { return "unknown" }
        let y = frame.y + frame.height / 2
        let neighbours = observation.elements.filter { other in
            guard other.id != element.id, let f = other.frame, let label = other.label, !label.isEmpty else { return false }
            return abs((f.y + f.height / 2) - y) < 30
        }.compactMap(\.label)
        return neighbours.isEmpty ? "no other label on the row" : neighbours.prefix(6).map { "'\($0)'" }.joined(separator: ", ")
    }
}

/// The outcome of asking for approval of one proposed step.
enum StepApproval: Equatable {
    case granted(source: String)
    /// A destructive action cannot be approved without a terminal (or the app listening for events).
    case needsTerminal
    case notGranted
}

extension CaseRunSession {
    /// Gets the approval for the pending step. A destructive action is approved by a person at the terminal (or through the app);
    /// everything else follows the mode's policy. Only an approval that the controller holds as `.approved` counts.
    func approve(_ step: IRStep, rowID: String, observation: Observation) -> StepApproval {
        let approved: Bool
        var approvedBy = mode.isLive ? "explicitAutomationPolicy" : "explicitAutomationPolicy (non-live)"
        if !allowDestructive, DestructiveActionGate.isDestructive(step) {
            // A person approves this one: a trash icon carries no name, so it can silently belong to the wrong item.
            guard isatty(STDIN_FILENO) != 0 || Engine.emitsEvents else { return .needsTerminal }
            let context = DestructiveActionGate.rowContext(of: step, in: observation)
            Engine.emit(["t": "activity", "kind": "wait", "text": "Waiting for you to approve: \(step.intent.prefix(90))"])
            Engine.emit(["t": "prompt", "id": "approve-\(rowID)", "kind": "approval", "title": "Approve a critical action",
                                         "message": "\(step.intent)\nTarget: \(step.target?.label ?? step.target?.identifier ?? "?")\nOther labels on the same row: \(context)", "secure": false,
                                         "timeout": Int(Self.personWaitSeconds)])
            print("\n!!! DESTRUCTIVE ACTION: a human must approve it.")
            print("    Step:   \(step.intent)")
            print("    Target: \(step.target?.label ?? step.target?.identifier ?? "?") (\(step.target?.role ?? "?"))")
            print("    Other labels on the same row: \(context)")
            approved = Engine.requestSupervisorApproval(mode: .liveHumanApproval, controller: controller, stepLabel: "\(rowID) ('\(step.intent)')")
            approvedBy = "humanCLI"
            Engine.emit(["t": "prompt-done", "id": "approve-\(rowID)"])
        } else {
            approved = Engine.requestSupervisorApproval(mode: mode, controller: controller, stepLabel: "\(rowID) ('\(step.intent)')")
        }
        return approved && controller.activeApproval?.status == .approved ? .granted(source: approvedBy) : .notGranted
    }
}
