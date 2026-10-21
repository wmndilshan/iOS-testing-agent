import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

/// A model that decides from the tools it was given which agent it is standing in for, and answers from a script.
private final class FakeBrain: ToolCallingLLM, @unchecked Sendable {
    let modelName: String
    private let lock = NSLock()
    private(set) var turns: [String] = []
    private let verdicts: @Sendable (Int) -> Bool
    private var verifyCalls = 0
    private let plan: [[String: AnyCodableValue]]

    init(name: String, plan: [[String: AnyCodableValue]] = [], verdicts: @escaping @Sendable (Int) -> Bool = { _ in true }) {
        modelName = name
        self.plan = plan
        self.verdicts = verdicts
    }

    func respond(system: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let names = Set(tools.map(\.name))
        let answered = messages.contains { if case .toolResult = $0 { true } else { false } }
        var events: [AgentEvent] = []
        func call(_ name: String, _ arguments: [String: AnyCodableValue]) { events = [.toolCall(ToolCall(id: UUID().uuidString, name: name, arguments: arguments), opaque: nil)] }
        let role: String
        if names.contains("set_plan") {
            role = "plan"
            if answered { events = [.textDelta("planned")] } else { call("set_plan", ["goals": .array(plan.map { .dictionary($0) })]) }
        } else if names.contains("report_verdict") {
            role = "verify"
            if answered { events = [.textDelta("verdict given")] } else {
                let n = lock.withLock { verifyCalls += 1; return verifyCalls }
                call("report_verdict", ["passed": .bool(verdicts(n)), "evidence": .string(verdicts(n) ? "It is there." : "It is not there.")])
            }
        } else if names.contains("report_finding") {
            role = "inspect"
            if answered { events = [.textDelta("found")] } else { call("report_finding", ["answer": .string("The first heading is Apple")]) }
        } else if names.contains("device_input") {
            role = "navigate"
            if answered { events = [.textDelta("Tapped Settings.")] } else { call("device_input", ["command": .string("tap"), "handle": .string("#1")]) }
        } else {
            role = "other"
            events = [.textDelta("done")]
        }
        lock.withLock { turns.append(role) }
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func count(_ role: String) -> Int { lock.withLock { turns.filter { $0 == role }.count } }
}

/// A fake app: a screen with a Settings button, and the commands it was asked to run.
private final class FakeDevice: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [DeviceCommandKind] = []
    private var reads = 0

    var bridge: DeviceBridge {
        DeviceBridge { [self] command in
            let n = lock.withLock { commands.append(command.kind); if command.kind == .readScreen { reads += 1 }; return reads }
            switch command.kind {
            case .readScreen:
                let screen = "Screen 402x874 (v\(n))\nControls:\n#1 button “Settings” (140,222)\n#2 button “Orders” (20,500)\nText: “Welcome”"
                return n == 1 ? screen : "Changed since the last read (v\(n)): 1 new, 0 gone, 0 changed; 2 controls now.\n+ #3 button “Done” (10,10)\n---\n" + screen
            case .tap: return "Tapped #1 “Settings” at (140, 222)."
            default: return "Done."
            }
        }
    }
    func count(_ kind: DeviceCommandKind) -> Int { lock.withLock { commands.filter { $0 == kind }.count } }
}

private func goal(_ text: String, kind: String = "navigate", expected: String) -> [String: AnyCodableValue] {
    ["text": .string(text), "kind": .string(kind), "expected": .string(expected)]
}

@Suite("Agent graph engine")
struct AgentGraphEngineTests {
    private let node = GraphNode(name: "a", kind: .function) { _ in }

    @Test("A graph needs its entry, an edge for every node, and edges that point at nodes")
    func validation() {
        let b = GraphNode(name: "b", kind: .function) { _ in }
        #expect(throws: Never.self) { try AgentGraph(nodes: ["a": node, "b": b], edges: ["a": .next("b"), "b": .end], entry: "a", maxSteps: 5).validate() }
        #expect(throws: AgentGraph.Invalid.unknownEntry("zzz")) { try AgentGraph(nodes: ["a": node], edges: ["a": .end], entry: "zzz", maxSteps: 5).validate() }
        #expect(throws: AgentGraph.Invalid.missingEdge("b")) { try AgentGraph(nodes: ["a": node, "b": b], edges: ["a": .next("b")], entry: "a", maxSteps: 5).validate() }
        #expect(throws: AgentGraph.Invalid.missingNode("nowhere")) { try AgentGraph(nodes: ["a": node], edges: ["a": .next("nowhere")], entry: "a", maxSteps: 5).validate() }
    }

    @Test("The default teams respect the fan-out limits; a lead with too many workers, too many leads, or a repeated name is refused")
    func hierarchy() throws {
        try OperatorHierarchy().validate()
        #expect(OperatorHierarchy().leads.map(\.name) == ["Perception lead", "Action lead", "Quality lead"], "no code lead: Operate never reads a repository")
        #expect(throws: OperatorHierarchy.Invalid.tooManyWorkers(lead: "L", count: 4)) { try OperatorHierarchy(leads: [.init(name: "L", workers: ["a", "b", "c", "d"])]).validate() }
        #expect(throws: OperatorHierarchy.Invalid.tooManyLeads(5)) { try OperatorHierarchy(leads: (1...5).map { .init(name: "L\($0)", workers: []) }).validate() }
        #expect(throws: OperatorHierarchy.Invalid.duplicate("Navigator")) { try OperatorHierarchy(leads: [.init(name: "A", workers: ["Navigator"]), .init(name: "B", workers: ["Navigator"])]).validate() }
    }

    @Test("State replies split into changes and screen; a plain digest is all screen; quoted labels on screen pass without a model")
    func helpers() {
        let (changes, full) = OperatorGraph.split("changed a\n---\nScreen b")
        #expect(changes == "changed a" && full == "Screen b")
        #expect(OperatorGraph.split("Screen only").changes.isEmpty)
        #expect(OperatorGraph.quickVerdict(expected: "Shows 'Settings' and 'Orders'", screen: "#1 button “Settings”\n#2 button “Orders”")?.contains("“Settings”") == true)
        #expect(OperatorGraph.quickVerdict(expected: "Shows 'Settings' and 'Cart'", screen: "#1 button “Settings”") == nil)
        #expect(OperatorGraph.quickVerdict(expected: "The page looks right", screen: "anything") == nil, "no quoted label: a model must judge")
    }
}

@Suite("Reading the screen after an action")
struct SettledReadTests {
    private actor Script {
        private var replies: [String]
        private(set) var modes: [String] = []
        init(_ replies: [String]) { self.replies = replies }
        func next(_ command: DeviceCommand) -> String {
            modes.append(command.string("mode") ?? "")
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
    }

    @Test("A screen still moving is read again until two reads agree; the first read's changes are kept")
    func settles() async {
        let script = Script(["changed: sheet\n---\nScreen A", "Screen B", "Screen C", "Screen C"])
        let board = OperatorBoard()
        await OperatorGraph.readScreen(board, DeviceBridge { command in await script.next(command) }, settle: true)
        let full = await board.screenFull, changes = await board.screenChanges, modes = await script.modes
        #expect(full == "Screen C" && changes == "changed: sheet")
        #expect(modes == ["state", "full", "full", "full"])
    }

    @Test("Without settle it reads once, and a screen that is already stable is read twice at most")
    func once() async {
        let script = Script(["Screen A"])
        let board = OperatorBoard()
        await OperatorGraph.readScreen(board, DeviceBridge { command in await script.next(command) })
        let first = await script.modes
        #expect(first == ["state"])
        await OperatorGraph.readScreen(board, DeviceBridge { command in await script.next(command) }, settle: true)
        let second = await script.modes, screen = await board.screenFull
        #expect(second == ["state", "state", "full"] && screen == "Screen A")
    }

    @Test("A failed read is reported as unreadable and not retried")
    func failure() async {
        let board = OperatorBoard()
        await OperatorGraph.readScreen(board, DeviceBridge { _ in "FAILED: no idb" }, settle: true)
        let screen = await board.screenFull
        #expect(screen.contains("could not be read"))
    }
}

@Suite("Knowing when the screen is stale")
struct ScreenFreshnessTests {
    @Test("A read makes the screen fresh; an action or a person's turn makes it stale; reading goals leave it alone")
    func freshness() async {
        let board = OperatorBoard()
        await board.start(task: "t")
        await board.setGoals([OperatorGoal(number: 1, text: "a", kind: .navigate, expected: "x")])
        _ = await board.selectNext()
        #expect(await board.screenFresh == false)
        await board.setScreen(full: "A", changes: "")
        #expect(await board.screenFresh)
        _ = await board.beginAttempt(changesScreen: false)
        #expect(await board.screenFresh, "an inspect or a check does not change the screen")
        _ = await board.beginAttempt()
        #expect(await board.screenFresh == false, "an action does")
        await board.setScreen(full: "B", changes: "")
        await board.markScreenStale()
        #expect(await board.screenFresh == false)
    }

    @Test("A resume is reported once, and only when there was a pause")
    func resumed() async {
        let gate = PauseGate()
        await gate.resume()
        let none = await gate.takeResumed()
        #expect(none == false)
        await gate.pause()
        await gate.resume()
        let first = await gate.takeResumed(), second = await gate.takeResumed()
        #expect(first && !second)
    }
}

@MainActor
@Suite("Operator graph run")
struct OperatorGraphRunTests {
    private func run(plan: [[String: AnyCodableValue]], verdicts: @escaping @Sendable (Int) -> Bool = { _ in true }, replan: [[String: AnyCodableValue]] = [], maxSteps: Int = 120,
                     gate: PauseGate = PauseGate()) async throws -> (AgentGraph.Outcome, OperatorBoard, FakeDevice, FakeBrain, FakeBrain) {
        let device = FakeDevice()
        let fast = FakeBrain(name: "fast", plan: plan, verdicts: verdicts)
        let strong = FakeBrain(name: "strong", plan: replan)
        let board = OperatorBoard()
        await board.start(task: "do the thing")
        let team = OperatorTeam(strong: strong, fast: fast, bridge: device.bridge, board: board, gate: gate)
        let base = OperatorGraph.make(team: team, board: board, bridge: device.bridge, reporter: AgentReporter(), state: AgentState(maxLLMCalls: 200))
        let graph = AgentGraph(nodes: base.nodes, edges: base.edges, entry: base.entry, maxSteps: maxSteps)
        let outcome = try await graph.run(board: board, reporter: AgentReporter(), gate: gate)
        return (outcome, board, device, fast, strong)
    }

    @Test("A plan runs goal by goal: read the screen, act, read again, verify; a quoted label that is on screen is verified without a model")
    func happyPath() async throws {
        let (outcome, board, device, fast, _) = try await run(plan: [goal("Tap Settings", expected: "Shows 'Settings'"), goal("Check the title", kind: "verify", expected: "Shows 'Orders'")])
        #expect(outcome == .finished)
        let succeeded = await board.succeeded
        let states = await board.goals.map(\.state)
        #expect(succeeded && states == [.done, .done])
        #expect(device.count(.tap) == 1)
        #expect(fast.count("verify") == 0, "both goals quote labels that are on screen")
        #expect(fast.count("navigate") == 2 && fast.count("plan") == 2, "the plan call and its answer; one navigator call and its answer")
        let actions = await board.sessionActions
        #expect(actions == ["Tapped Settings."])
    }

    @Test("The verifier is asked only when the quick check cannot decide, and its verdict is used")
    func verifierUsed() async throws {
        let (_, board, _, fast, _) = try await run(plan: [goal("Tap Settings", expected: "The settings page is open")])
        let succeeded = await board.succeeded
        let evidence = await board.goals[0].evidence
        #expect(fast.count("verify") == 2 && succeeded)
        #expect(evidence == "It is there.")
    }

    @Test("A goal that keeps failing is tried three times, then the strong model plans again, then the run reports the failure")
    func retryReplanFail() async throws {
        let (outcome, board, device, fast, strong) = try await run(plan: [goal("Tap Settings", expected: "The settings page is open")], verdicts: { _ in false },
                                                                    replan: [goal("Try another way", expected: "Another page")])
        #expect(outcome == .finished)
        let succeeded = await board.succeeded
        #expect(!succeeded)
        let goals = await board.goals
        let replans = await board.replans
        #expect(goals.first?.state == .failed && goals.first?.attempts == OperatorGraph.maxAttempts)
        #expect(replans == 1 && strong.count("plan") == 2, "planned again once, with the strong model")
        #expect(goals.count == 2, "the new plan replaced what was not done")
        #expect(fast.count("navigate") >= OperatorGraph.maxAttempts * 2 && device.count(.tap) >= OperatorGraph.maxAttempts)
    }

    @Test("A check-only goal that never passes still counts its tries: three, then it fails, instead of looping to the step cap")
    func verifyOnlyGoalIsBounded() async throws {
        let (outcome, board, _, fast, _) = try await run(plan: [goal("Check dark mode", kind: "verify", expected: "The screen is dark")], verdicts: { _ in false })
        let goal = await board.goals.first
        #expect(outcome == .finished, "ended by itself, not by the step limit")
        #expect(goal?.attempts == OperatorGraph.maxAttempts && goal?.state == .failed)
        #expect(fast.count("verify") <= 2 * (OperatorGraph.maxAttempts + 1))
    }

    @Test("A goal that fails once and then passes is not failed")
    func retryThenPass() async throws {
        let (_, board, _, _, _) = try await run(plan: [goal("Tap Settings", expected: "The settings page is open")], verdicts: { $0 >= 2 })
        let succeeded = await board.succeeded
        let attempts = await board.goals[0].attempts
        #expect(succeeded && attempts == 2)
    }

    @Test("An inspect goal records what was found and is done")
    func inspect() async throws {
        let (_, board, _, _, _) = try await run(plan: [goal("Read the first heading", kind: "inspect", expected: "The heading")])
        let findings = await board.findings
        let succeeded = await board.succeeded
        let evidence = await board.goals[0].evidence
        #expect(findings == ["The first heading is Apple"] && succeeded)
        #expect(evidence == "The first heading is Apple")
    }

    @Test("Stopping ends the run at the next safe point")
    func stop() async throws {
        let gate = PauseGate()
        await gate.stop()
        let (outcome, _, device, _, _) = try await run(plan: [goal("Tap Settings", expected: "Shows 'Settings'")], gate: gate)
        #expect(outcome == .stopped && device.commands.isEmpty)
    }

    @Test("A paused run waits where it is and carries on, with its state, when resumed")
    func pauseAndResume() async throws {
        let gate = PauseGate()
        await gate.pause()
        async let result = run(plan: [goal("Tap Settings", expected: "Shows 'Settings'")], gate: gate)
        try await Task.sleep(nanoseconds: 300_000_000)
        await gate.resume()
        let (outcome, board, device, _, _) = try await result
        let succeeded = await board.succeeded
        #expect(outcome == .finished && succeeded && device.count(.tap) == 1)
    }

    @Test("A run that never settles stops at the step limit")
    func stepLimit() async throws {
        let (outcome, _, _, _, _) = try await run(plan: [goal("Tap Settings", expected: "Shows 'Settings'")], maxSteps: 4)
        #expect(outcome == .stepLimit)
    }
}
