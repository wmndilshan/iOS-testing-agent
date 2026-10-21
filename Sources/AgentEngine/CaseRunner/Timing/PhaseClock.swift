import Foundation
import AgentCore
import AgentInfrastructure

/// The phases of a case step that take time. Anything not inside one of them counts as "other" (observations, bookkeeping).
enum RunPhase: String, CaseIterable {
    /// Planning the action with a model and dispatching it.
    case plan
    /// Waiting for the screen to stop changing.
    case settle
    /// The screenshot judge.
    case judge
    /// The checks after a judge pass.
    case check
    /// Replaying a learned skill.
    case replay
}

extension RunPhase {
    /// The kind the app uses for the live activity line.
    var activityKind: String {
        switch self {
        case .plan: "plan"
        case .settle: "settle"
        case .judge: "judge"
        case .check: "check"
        case .replay: "replay"
        }
    }
}

/// Measures where a step's time goes. A phase started inside another pauses the outer one, so nothing is counted twice.
@MainActor
final class PhaseClock {
    private var step = 0
    private var startedAt = Date()
    private var stack: [(phase: RunPhase, since: Date)] = []
    private var phases: [RunPhase: Double] = [:]
    private(set) var timing = RunTiming()

    /// Starts timing a step.
    func begin(step number: Int) {
        step = number
        startedAt = Date()
        phases = [:]
        stack = []
    }

    /// Times `body` as `phase`. The app is told what is happening (`label`) so it can show it live.
    func measure<T>(_ phase: RunPhase, _ label: String? = nil, _ body: () async -> T) async -> T {
        if let label, step > 0 { Engine.activity(step: step, kind: phase.activityKind, label) }
        let now = Date()
        if let outer = stack.last { phases[outer.phase, default: 0] += now.timeIntervalSince(outer.since) }
        stack.append((phase, now))
        let result = await body()
        let end = Date()
        if let inner = stack.popLast() { phases[inner.phase, default: 0] += end.timeIntervalSince(inner.since) }
        if !stack.isEmpty { stack[stack.count - 1].since = end }
        return result
    }

    /// Ends the step: records, prints and reports its timing.
    @discardableResult
    func finish() -> RunTiming.StepTime {
        let seconds = Date().timeIntervalSince(startedAt)
        let named = Dictionary(uniqueKeysWithValues: phases.map { ($0.key.rawValue, ($0.value * 10).rounded() / 10) })
        let entry = RunTiming.StepTime(seconds: (seconds * 10).rounded() / 10, phases: named)
        timing.steps["\(step)"] = entry
        print("  Step \(step) took \(Self.describe(entry))")
        Engine.emit(["t": "timing", "step": step, "seconds": entry.seconds, "phases": named])
        return entry
    }

    /// "12 s: plan 4, judge 5, settle 2, other 1".
    static func describe(_ time: RunTiming.StepTime) -> String {
        let parts = RunPhase.allCases.compactMap { phase -> String? in
            guard let value = time.phases[phase.rawValue], value >= 0.5 else { return nil }
            return "\(phase.rawValue) \(Int(value.rounded()))"
        }
        let other = max(0, time.seconds - time.phases.values.reduce(0, +))
        return "\(Int(time.seconds.rounded())) s" + (parts.isEmpty ? "" : ": " + (parts + (other >= 0.5 ? ["other \(Int(other.rounded()))"] : [])).joined(separator: ", "))
    }
}
