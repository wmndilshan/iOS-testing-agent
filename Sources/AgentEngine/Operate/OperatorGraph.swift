import Foundation
import AgentCore
import AgentInfrastructure

/// Who controls whom: the Orchestrator controls the leads, each lead controls a few workers. Fan-out is limited so no supervisor has more to coordinate
/// than it can keep in mind; the graph checks it before running.
struct OperatorHierarchy: Sendable, Equatable {
    struct Lead: Sendable, Equatable {
        let name: String
        let workers: [String]
    }

    static let orchestrator = "Orchestrator"
    static let maxLeads = 4
    static let maxWorkersPerLead = 3

    let leads: [Lead]

    /// Operate works from the screen alone: it never reads a repository, so there is no code lead.
    init() {
        leads = [Lead(name: "Perception lead", workers: ["Reader", "Inspector"]),
                 Lead(name: "Action lead", workers: ["Navigator", "Configurator"]),
                 Lead(name: "Quality lead", workers: ["Verifier"])]
    }

    init(leads: [Lead]) { self.leads = leads }

    enum Invalid: Error, Equatable { case tooManyLeads(Int), tooManyWorkers(lead: String, count: Int), duplicate(String) }

    func validate() throws {
        guard leads.count <= Self.maxLeads else { throw Invalid.tooManyLeads(leads.count) }
        var names = Set<String>([Self.orchestrator])
        for lead in leads {
            guard lead.workers.count <= Self.maxWorkersPerLead else { throw Invalid.tooManyWorkers(lead: lead.name, count: lead.workers.count) }
            for name in [lead.name] + lead.workers { guard names.insert(name).inserted else { throw Invalid.duplicate(name) } }
        }
    }

    var payload: [[String: Any]] { leads.map { ["lead": $0.name, "workers": $0.workers] } }
}

/// The operating run as a graph: plan, then for each goal read the screen, act, read again, verify, and decide (next goal, retry, re-plan, finish) in code.
/// The only model calls are the plan, one worker per action and, when the digest is not enough, a verifier.
enum OperatorGraph {
    /// A goal gets this many tries (the first and two more) before it counts as failed.
    static let maxAttempts = 3
    static let maxSteps = 120

    static func make(team: OperatorTeam, board: OperatorBoard, bridge: DeviceBridge, reporter: AgentReporter, state: AgentState) -> AgentGraph {
        @Sendable func emitPlan() async { reporter.send(["t": "graph-plan", "goals": OperatorBoard.payload(await board.goals)]) }

        // Function nodes
        let observe = GraphNode(name: "observe", kind: .function) { board in
            // The screen read after the last action (or at the start) is still what the device shows: do not read it again.
            if await board.screenFresh { return }
            await readScreen(board, bridge)
        }
        let observeAfter = GraphNode(name: "observe_after", kind: .function) { board in await readScreen(board, bridge, settle: true) }
        let observeStart = GraphNode(name: "observe_start", kind: .function) { board in await readScreen(board, bridge) }
        let select = GraphNode(name: "select", kind: .function) { board in
            _ = await board.selectNext()
            await emitPlan()
        }
        // Agent nodes
        let plan = GraphNode(name: "plan", kind: .agent) { board in
            _ = try await team.planner.run(task: await planTask(board), state: state, reporter: reporter)
            if await board.goals.isEmpty {
                let task = await board.task
                await board.setGoals([OperatorGoal(number: 1, text: task, kind: .navigate, expected: "The task is done")])
            }
            await emitPlan()
        }
        let replan = GraphNode(name: "replan", kind: .agent) { board in
            reporter.send(["t": "activity", "kind": "plan", "text": "A goal failed: planning again with the strong model"])
            _ = try await team.replanner.run(task: await replanTask(board), state: state, reporter: reporter)
            await emitPlan()
        }
        func action(_ name: String, _ agent: Agent) -> GraphNode {
            GraphNode(name: name, kind: .agent) { board in
                guard let goal = await board.beginAttempt() else { return }
                await emitPlan()
                let done = await board.actions(for: goal.number)
                let report = try await agent.run(task: await actionTask(goal, board: board, done: done), state: state, reporter: reporter)
                await board.record(action: String(report.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)))
            }
        }
        let inspect = GraphNode(name: "inspect", kind: .agent) { board in
            guard let goal = await board.beginAttempt(changesScreen: false) else { return }
            await emitPlan()
            let before = await board.findings.count
            _ = try await team.inspector.run(task: await actionTask(goal, board: board, done: []), state: state, reporter: reporter)
            if await board.findings.count > before, let answer = await board.findings.last {
                await board.complete(evidence: answer)
            } else {
                await board.miss(note: "The inspector found nothing.", retry: goal.attempts < maxAttempts)
            }
            await emitPlan()
        }
        let verify = GraphNode(name: "verify", kind: .agent) { board in
            // A goal that only checks something goes straight here, so this is its attempt: without counting it a goal that never passes would be retried for ever.
            if await board.currentGoal?.state == .pending { _ = await board.beginAttempt(changesScreen: false); await emitPlan() }
            guard let goal = await board.currentGoal else { return }
            await board.clearVerdict()
            // The cheap check first: every label the expected result quotes is on screen now. No model call.
            let screen = await board.screenFull
            if let confirmed = quickVerdict(expected: goal.expected, screen: screen) {
                await board.setVerdict(passed: true, evidence: confirmed)
                return
            }
            _ = try await team.verifier.run(task: await verifyTask(goal, board: board), state: state, reporter: reporter)
            if await board.verdict == nil { await board.setVerdict(passed: false, evidence: "The verifier gave no verdict.") }
        }
        let report = GraphNode(name: "report", kind: .function) { board in
            let succeeded = await board.succeeded
            reporter.send(["t": "operate-final", "status": succeeded ? "done" : "failed", "summary": await board.summary(), "goals": OperatorBoard.payload(await board.goals),
                           "actions": await board.sessionActions])
        }

        // Edges: code, not model calls.
        @Sendable func dispatch(_ board: OperatorBoard) async -> String {
            switch await board.currentGoal?.kind ?? .navigate {
            case .navigate: "navigate"
            case .configure: "configure"
            case .inspect: "inspect"
            case .verify: "verify"
            }
        }
        let nodes = [observeStart, plan, select, observe, action("navigate", team.navigator), action("configure", team.configurator), inspect, observeAfter, verify, replan, report]
        let edges: [String: GraphEdge] = [
            "observe_start": .next("plan"),
            "plan": .next("select"),
            "select": .branch { board in await board.currentGoal == nil ? "report" : "observe" },
            "observe": .branch(dispatch),
            "navigate": .next("observe_after"),
            "configure": .next("observe_after"),
            "inspect": .branch { board in await board.currentGoal?.state == .pending ? "observe" : "select" },
            "observe_after": .next("verify"),
            "verify": .branch { board in
                if let reason = await board.blocked {
                    // The person is needed: hold here, show why, and look again after they have taken over and resumed.
                    reporter.send(["t": "operate-blocked", "reason": reason])
                    await team.gate.pause()
                    await board.markScreenStale()
                    await board.clearBlocked()
                    await board.clearVerdict()
                    return "observe"
                }
                guard let goal = await board.currentGoal, let verdict = await board.verdict else { return "select" }
                if verdict.passed { await board.complete(evidence: verdict.evidence); await emitPlan(); return "select" }
                if goal.attempts < maxAttempts {
                    await board.miss(note: verdict.evidence, retry: true)
                    await emitPlan()
                    return "observe"
                }
                await board.miss(note: verdict.evidence, retry: false)
                await emitPlan()
                return await board.replans < 1 ? "replan" : "report"
            },
            "replan": .next("select"),
            "report": .end,
        ]
        return AgentGraph(nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) }), edges: edges, entry: "observe_start", maxSteps: maxSteps)
    }

    // MARK: Reading the screen

    /// One read of the screen through the app: the whole digest, and what changed since the read before it.
    ///
    /// With `settle`, the screen is read again until two reads in a row agree (at most three more times, 350 ms apart): right after an action the screen is
    /// often still moving (a sheet sliding up, a page loading), and judging it then fails goals that were about to pass. The changes the first read
    /// reported are kept; the screen is the settled one.
    static func readScreen(_ board: OperatorBoard, _ bridge: DeviceBridge, settle: Bool = false) async {
        let text = await bridge.run(.readScreen, ["mode": .string("state")])
        if text.hasPrefix("FAILED:") {
            await board.setScreen(full: "(The screen could not be read: \(text.dropFirst(8)))", changes: "")
            return
        }
        let (changes, first) = split(text)
        var settled = first
        if settle {
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                let again = await bridge.run(.readScreen, ["mode": .string("full")])
                if again.hasPrefix("FAILED:") || again == settled { break }
                settled = again
            }
        }
        await board.setScreen(full: settled, changes: changes)
    }

    /// `state` replies are "changes --- screen"; a plain digest has only the screen.
    static func split(_ text: String) -> (changes: String, full: String) {
        guard let range = text.range(of: "\n---\n") else { return ("", text) }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    // MARK: Task text for each agent. Stable parts first, the screen last.

    static func planTask(_ board: OperatorBoard) async -> String {
        var text = "Task: \(await board.task)\n"
        text += "\nThe screen now:\n\(await board.screenFull)"
        return text
    }

    static func replanTask(_ board: OperatorBoard) async -> String {
        var text = "Task: \(await board.task)\nSo far:\n\(await board.summary())\n"
        text += "\nA goal failed after several tries. Plan only what is still to do, differently if the same approach did not work. Do not repeat finished goals.\n"
        text += "\nThe screen now:\n\(await board.screenFull)"
        return text
    }

    static func actionTask(_ goal: OperatorGoal, board: OperatorBoard, done: [String]) async -> String {
        var text = "Goal \(goal.number) of \(await board.goals.count): \(goal.text)\nExpected afterwards: \(goal.expected)\nTry \(goal.attempts) of \(maxAttempts)."
        if !goal.note.isEmpty { text += "\nThe last try did not work: \(goal.note)" }
        if !done.isEmpty { text += "\nDone for this goal so far: " + done.suffix(4).joined(separator: " | ") }
        let changes = await board.screenChanges
        text += "\n\nThe screen now:\n\(await board.screenFull)"
        if !changes.isEmpty { text += "\n\nChanged by the last action:\n\(changes)" }
        return text
    }

    static func verifyTask(_ goal: OperatorGoal, board: OperatorBoard) async -> String {
        var text = "Goal: \(goal.text)\nExpected: \(goal.expected)"
        let done = await board.actions(for: goal.number)
        let confirmed = done.filter { $0.hasPrefix("Result: ") }.suffix(2).map { String($0.dropFirst(8)) }
        if !confirmed.isEmpty { text += "\nConfirmed by the device itself: " + confirmed.joined(separator: " | ") }
        else if let latest = await board.recentResults.last { text += "\nLatest confirmation from the device (from an earlier goal; still true unless a later action changed it): " + latest }
        let did = done.filter { !$0.hasPrefix("Result: ") }
        if !did.isEmpty { text += "\nWhat was done for it: " + did.suffix(3).joined(separator: " | ") }
        text += "\n\nThe screen now:\n\(await board.screenFull)"
        let changes = await board.screenChanges
        if !changes.isEmpty { text += "\n\nChanged by the last action:\n\(changes)" }
        return text
    }

    /// The expected result quotes labels ('Mine'), and every one of them is on the screen: that is a pass without asking a model.
    static func quickVerdict(expected: String, screen: String) -> String? {
        let labels = QuickChecks.labels(in: expected)
        guard !labels.isEmpty else { return nil }
        let haystack = screen.lowercased()
        guard labels.allSatisfy({ haystack.contains($0.lowercased()) }) else { return nil }
        return "On screen now: " + labels.map { "“\($0)”" }.joined(separator: ", ")
    }
}
