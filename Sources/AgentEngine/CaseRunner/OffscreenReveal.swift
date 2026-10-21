import Foundation
import AgentCore
import AgentInfrastructure

extension CaseRunSession {
    /// True when the target's element is in the tree but not tappable because it lies outside the window.
    func isOffscreen(_ target: IRTarget, in observation: Observation) -> Bool {
        guard let width = observation.application?.windowWidth.map(Double.init), let height = observation.application?.windowHeight.map(Double.init) else { return false }
        let matches = observation.elements.filter { element in
            guard element.role == target.role else { return false }
            if let identifier = target.identifier, !identifier.isEmpty { return element.identifier == identifier }
            return element.label == target.label
        }
        guard matches.count == 1, let element = matches.first, !element.isHittable, let frame = element.frame, frame.width > 0 else { return false }
        let x = frame.x + frame.width / 2, y = frame.y + frame.height / 2
        return x > width || x < 0 || y > height || y < 0
    }

    /// When a step's target exists but is scrolled off screen, scroll its row or column toward it. The scroll is an
    /// ordinary step: it is validated, approved by the mode's policy, dispatched and recorded like any other.
    /// Returns true when a scroll was dispatched, so the caller observes again and plans again.
    func revealOffscreenTarget(mentionedIn text: String, exactTarget: IRTarget? = nil, observation: Observation, number: Int, attempt: Int) async -> Bool {
        guard let width = observation.application?.windowWidth.map(Double.init), let height = observation.application?.windowHeight.map(Double.init) else { return false }
        let lowered = text.lowercased()
        func mentioned(_ element: UIElementSnapshot) -> Bool {
            // A target the planner already named is matched exactly; free text is only a hint when planning was blocked.
            if let exactTarget {
                if let identifier = exactTarget.identifier, !identifier.isEmpty { return element.identifier == identifier }
                return element.role == exactTarget.role && element.label == exactTarget.label
            }
            if let label = element.label?.lowercased(), label.count >= 3, lowered.contains(label) { return true }
            if let tail = element.identifier?.lowercased().split(separator: "-").last, tail.count >= 3, lowered.contains(String(tail)) { return true }
            return false
        }
        func center(_ frame: ElementFrame) -> (x: Double, y: Double) { (frame.x + frame.width / 2, frame.y + frame.height / 2) }
        guard let target = observation.elements.first(where: { element in
            guard !element.isHittable, element.isEnabled, let frame = element.frame, frame.width > 0, frame.height > 0, mentioned(element) else { return false }
            let c = center(frame)
            return c.x > width || c.x < 0 || c.y > height || c.y < 0
        }), let targetFrame = target.frame else { return false }
        let t = center(targetFrame)
        let horizontal = t.x > width || t.x < 0
        let direction = horizontal ? (t.x > width ? "right" : "left") : (t.y > height ? "down" : "up")
        // The scrolling container is not in idb's tree, so use the widest visible element in the same row (or column).
        let anchor = observation.elements.filter { element in
            guard element.isHittable, let frame = element.frame, element.identifier != nil || element.label != nil else { return false }
            let c = center(frame)
            return horizontal ? abs(c.y - t.y) < 40 : abs(c.x - t.x) < 40
        }.max { ($0.frame?.width ?? 0) * ($0.frame?.height ?? 0) < ($1.frame?.width ?? 0) * ($1.frame?.height ?? 0) }
        guard let anchor else { return false }
        let step = IRStep(id: "s1", sourceStepNumber: number, intent: "Scroll \(direction) to bring '\(target.label ?? target.identifier ?? "the target")' into view",
                          action: .scroll, target: IRTarget(role: anchor.role, identifier: anchor.identifier, label: anchor.label),
                          arguments: ["direction": .string(direction)],
                          verification: IRVerification(description: "the scroll was dispatched and the application is still in the foreground", signals: [.foregroundApplication(bundleID: bundleID)]))
        print("    target '\(target.label ?? target.identifier ?? "?")' is scrolled off screen; scrolling \(direction) from '\(anchor.label ?? anchor.identifier ?? "?")' (\(anchor.id), frame \(anchor.frame.map { "x=\(Int($0.x)) y=\(Int($0.y)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "none"), hittable \(anchor.isHittable)) (attempt \(attempt))")
        return await runDocument(ir: TestIR(testKey: key, title: title, steps: [step]), rowPrefix: "\(number).reveal\(attempt).", stepNumber: number, startStep: 0, humanNumbers: [])
    }
}
