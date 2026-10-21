import Foundation

enum GoalKind: String, Sendable, CaseIterable {
    /// Move around the app: tap, type, scroll.
    case navigate
    /// Change the device: open a link, launch an app, a permission, the location, the appearance.
    case configure
    /// Find something out: read what is on screen. No change to the device.
    case inspect
    /// Only check that something is true now.
    case verify
}

enum GoalState: String, Sendable {
    case pending, working, done, failed
}

/// One small, observable step of the task, with how to tell it worked.
struct OperatorGoal: Sendable, Equatable {
    var number: Int
    var text: String
    var kind: GoalKind
    var expected: String
    var state: GoalState = .pending
    var attempts = 0
    /// Why the last try did not work (the verifier's words); the next try reads it.
    var note = ""
    /// What the verifier or inspector found.
    var evidence = ""
}

/// The shared state the agents of a run read and write: nobody re-reads the screen or the repository on their own, they read this. An actor, so
/// agents that run side by side cannot trample each other.
actor OperatorBoard {
    private(set) var task = ""
    private(set) var goals: [OperatorGoal] = []
    private(set) var current: Int?
    /// The screen as the last read left it: the full digest, and what changed since the read before it.
    private(set) var screenFull = ""
    private(set) var screenChanges = ""
    private var actionsByGoal: [Int: [String]] = [:]
    private(set) var findings: [String] = []
    private(set) var replans = 0
    private(set) var sessionActions: [String] = []
    /// What commands that change the device reported, latest last, across goals.
    private(set) var recentResults: [String] = []
    /// What the verifier concluded about the current goal.
    private(set) var verdict: (passed: Bool, evidence: String)?

    func setVerdict(passed: Bool, evidence: String) { verdict = (passed, evidence) }
    func clearVerdict() { verdict = nil }

    /// Set when the screen needs the person (a login, a code, a permission only they can give): the graph pauses and asks them to take over.
    private(set) var blocked: String?
    func setBlocked(_ reason: String) { blocked = reason }
    func clearBlocked() { blocked = nil }

    func start(task: String) {
        self.task = task
        goals = []
        current = nil
        screenFull = ""
        screenChanges = ""
        actionsByGoal = [:]
        findings = []
        replans = 0
        sessionActions = []
        recentResults = []
        verdict = nil
        blocked = nil
    }

    // MARK: Plan

    func setGoals(_ new: [OperatorGoal]) { goals = new; current = nil }

    /// A new plan after a failure: finished goals stay finished and failed ones stay on record (so the report shows them), the rest is replaced.
    func replan(with new: [OperatorGoal]) {
        let kept = goals.filter { $0.state == .done || $0.state == .failed }
        var numbered = kept
        for var goal in new {
            goal.number = numbered.count + 1
            numbered.append(goal)
        }
        goals = numbered
        current = nil
        replans += 1
    }

    /// The first goal not done yet, marked as the one being worked on.
    func selectNext() -> OperatorGoal? {
        guard let index = goals.firstIndex(where: { $0.state == .pending }) else { current = nil; return nil }
        goals[index].state = .working
        current = index
        return goals[index]
    }

    var currentGoal: OperatorGoal? { current.flatMap { goals.indices.contains($0) ? goals[$0] : nil } }

    func beginAttempt(changesScreen: Bool = true) -> OperatorGoal? {
        guard let current else { return nil }
        if changesScreen { screenFresh = false }
        goals[current].attempts += 1
        goals[current].state = .working
        return goals[current]
    }

    func complete(evidence: String) {
        guard let current else { return }
        goals[current].state = .done
        goals[current].evidence = evidence
        goals[current].note = ""
    }

    /// The last try did not work: the goal goes back to pending for another try, or is failed when it has had enough.
    func miss(note: String, retry: Bool) {
        guard let current else { return }
        goals[current].note = note
        goals[current].state = retry ? .pending : .failed
        // A goal that goes back to pending is the next one chosen again.
    }

    // MARK: Screen, actions, findings

    /// True while `screenFull` is what the device shows: set by a read, cleared when an action starts or a person may have touched the device. The next
    /// read is skipped while it holds, so a goal does not read again a screen it has just read.
    private(set) var screenFresh = false

    func setScreen(full: String, changes: String) { screenFull = full; screenChanges = changes; screenFresh = true }
    func markScreenStale() { screenFresh = false }

    func record(action: String) {
        guard let goal = currentGoal else { return }
        actionsByGoal[goal.number, default: []].append(action)
        sessionActions.append(action)
        if action.hasPrefix("Result: ") { recentResults.append(String(action.dropFirst(8))); recentResults = Array(recentResults.suffix(6)) }
    }

    func actions(for number: Int) -> [String] { actionsByGoal[number] ?? [] }
    func add(finding: String) { findings.append(finding) }

    // MARK: Reading it

    /// The goals as the app shows them (a plain value, so it can leave the actor).
    nonisolated static func payload(_ goals: [OperatorGoal]) -> [[String: Any]] {
        goals.map { ["number": $0.number, "text": $0.text, "kind": $0.kind.rawValue, "state": $0.state.rawValue, "attempts": $0.attempts, "expected": $0.expected] }
    }

    func summary() -> String {
        var lines: [String] = []
        for goal in goals {
            let mark = goal.state == .done ? "✓" : goal.state == .failed ? "✗" : "·"
            lines.append("\(mark) \(goal.number). \(goal.text)" + (goal.evidence.isEmpty ? "" : " — \(goal.evidence)") + (goal.state == .failed && !goal.note.isEmpty ? " (\(goal.note))" : ""))
        }
        if !findings.isEmpty { lines.append("Found: " + findings.joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }

    var succeeded: Bool { !goals.isEmpty && goals.allSatisfy { $0.state == .done } }
    var hasPending: Bool { goals.contains { $0.state == .pending } }
}
