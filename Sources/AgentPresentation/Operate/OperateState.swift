import Foundation
import AgentCore

/// One goal of the plan the Orchestrator made, as the checklist shows it.
public struct OperateGoal: Identifiable, Equatable, Sendable, Codable {
    public enum State: String, Sendable, Codable { case pending, active, done, failed }
    public let number: Int
    public var text: String
    public var kind: String
    public var state: State
    public var attempts: Int
    public var expected: String
    public var id: Int { number }
}

/// One thing an agent did or thought, as the events reported it. The goal cards are built from these; the raw form is never shown.
public struct OperateEntry: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case node, thought, text, tool, error, notice }
    public var id = UUID()
    public let kind: Kind
    public let agent: String
    /// The text of a thought, reply, node title or error; the tool's name for a tool call.
    public var text: String
    /// A tool call's arguments (JSON) and what it returned.
    public var args = ""
    public var summary = ""
    public var succeeded: Bool?
    public var callID = ""
    public var milliseconds: Int?
    /// The goal being worked on when it happened (0 before there is a plan).
    public var goal = 0
    /// A streamed thought or reply that may still grow.
    public var isOpen = false
    public var at = Date()

    public init(kind: Kind, agent: String, text: String, args: String = "", goal: Int = 0) {
        self.kind = kind
        self.agent = agent
        self.text = text
        self.args = args
        self.goal = goal
    }

    // Sessions saved by an earlier version lack the newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        args = try c.decodeIfPresent(String.self, forKey: .args) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        succeeded = try c.decodeIfPresent(Bool.self, forKey: .succeeded)
        callID = try c.decodeIfPresent(String.self, forKey: .callID) ?? ""
        milliseconds = try c.decodeIfPresent(Int.self, forKey: .milliseconds)
        goal = try c.decodeIfPresent(Int.self, forKey: .goal) ?? 0
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
    }
}

/// A lead and the workers it controls, for the team strip.
public struct OperateLead: Equatable, Sendable {
    public let name: String
    public let workers: [String]
}

public struct OperateUsage: Equatable, Sendable, Codable {
    public var seconds = 0, calls = 0, input = 0, output = 0, cached = 0
}

/// What a tap on the live view lands on, shown as a ring for a moment.
public struct OperateHighlight: Equatable, Sendable {
    public let point: DevicePoint
    public let byPerson: Bool
    public let at: Date
}

/// The Operate section: a task given to the graph of agents, which drives the simulator through the same approved device lane the chat uses.
/// It never reads a repository: it works from the screen alone. It owns its own agent process (`--operate`), reads its events, and lets the person pause, take over, resume or stop.
@MainActor
public final class OperateState: ObservableObject {
    public enum Phase: Equatable, Sendable { case idle, running, paused, finished(done: Bool) }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var task = ""
    @Published public private(set) var goals: [OperateGoal] = []
    @Published public private(set) var entries: [OperateEntry] = []
    @Published public private(set) var team: [OperateLead] = []
    @Published public private(set) var activeNode = ""
    @Published public private(set) var activeAgent = ""
    @Published public private(set) var summary = ""
    @Published public private(set) var usage = OperateUsage()
    /// Seconds spent in each part of the team, from the graph's node timings: who the time went to.
    @Published public private(set) var workerSeconds: [String: Double] = [:]
    @Published public private(set) var deviceApproval: DeviceApproval?
    @Published public private(set) var highlight: OperateHighlight?
    @Published public private(set) var recorded: [RecordedAction] = []
    @Published public private(set) var savedCaseKey: String?
    @Published public private(set) var modelName = ""
    /// Why the agents stopped and need the person (a login, a code): shown while paused, cleared on resume.
    @Published public private(set) var blockedReason: String?
    @Published public var notice: String?
    /// Earlier tasks, newest first, and the one on screen (nil for a new, empty one).
    @Published public private(set) var sessions: [OperateSessionSummary] = []
    @Published public private(set) var activeSessionID: UUID?
    @Published public var provider: String { didSet { defaults.set(provider, forKey: Self.providerKey) } }
    /// The person chose "let the agent operate for this task": reversible commands run without asking.
    @Published public var letAgentOperate = true

    static let providerKey = "operate.provider"
    private let launcher: any CaseRunLaunching
    private let handler: DeviceRequestHandler
    private let library: TestLibraryState?
    private let store: OperateSessionStore?
    private var humanQueue: Task<Void, Never>?
    private var typed = ""
    private var typingFlush: Task<Void, Never>?
    private let defaults: UserDefaults
    private var handle: (any CaseRunHandle)?
    private var currentGoal: Int?
    private var started = Date()

    public init(launcher: any CaseRunLaunching, handler: DeviceRequestHandler, library: TestLibraryState?,
                defaults: UserDefaults = .standard, store: OperateSessionStore? = nil) {
        self.store = store
        self.launcher = launcher
        self.handler = handler
        self.library = library
        self.defaults = defaults
        provider = defaults.string(forKey: Self.providerKey) ?? "deepseek"
        sessions = store?.list() ?? []
        handler.onApproval = { [weak self] in self?.deviceApproval = $0 }
        handler.onExecuted = { [weak self] in self?.executed($0) }
    }

    // MARK: State for the view

    public var startedAt: Date { started }

    /// What the agents found out, from the summary's "Found: a | b" line: the answer to a question in the task.
    public var findings: [String] {
        guard let line = summary.split(separator: "\n").last(where: { $0.hasPrefix("Found: ") }) else { return [] }
        return line.dropFirst("Found: ".count).components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The goals that did not pass, each with the reason the checks gave, without the plan's own numbering marks.
    public var unmetGoals: [String] {
        summary.split(separator: "\n").filter { $0.hasPrefix("✗ ") }.map { String($0.dropFirst(2)) }
    }

    /// The result as plain text, for copying into a report.
    public var resultText: String {
        var lines = ["Task: \(task)", "Outcome: " + (phase == .finished(done: true) ? "done" : "not finished")]
        for goal in goals { lines.append("- [\(goal.state == .done ? "x" : " ")] \(goal.text)") }
        if !findings.isEmpty { lines.append("Found: " + findings.joined(separator: "; ")) }
        lines.append("\(usage.seconds) s, \(usage.calls) model calls, \(usage.input + usage.output) tokens")
        return lines.joined(separator: "\n")
    }
    /// The goal being worked on, for the card to scroll to.
    public var activeGoalNumber: Int? { goals.first { $0.state == .active }?.number }
    public var isRunning: Bool { phase == .running || phase == .paused }
    public var isPaused: Bool { phase == .paused }
    public var isWaitingForPerson: Bool { deviceApproval != nil }
    public var deviceAvailable: Bool { handler.isAvailable }
    public var canSaveAsCase: Bool { !isRunning && !recorded.isEmpty && savedCaseKey == nil }
    public var plannedStepCount: Int { OperationRecorder.steps(goals: goals, actions: recorded).count }

    // MARK: Controls

    /// Starts the graph on a task. Ignored while one is running or with an empty task.
    public func start(_ text: String) {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !isRunning else { return }
        guard handler.isAvailable else {
            notice = "Device control is not available: idb was not found (see the README)."
            return
        }
        reset(task: task)
        activeSessionID = UUID()
        persist(status: "running")
        handler.resetGrants()
        if letAgentOperate { handler.allowReversible() }
        do {
            let run = try launcher.launch(arguments: ["--operate", "--events", "--provider=\(provider)", "--task=\(task)"])
            handle = run
            phase = .running
            Task { [weak self] in
                for await line in run.lines { self?.consume(line) }
                self?.processEnded(run)
            }
        } catch {
            entries.append(OperateEntry(kind: .error, agent: "", text: error.localizedDescription))
        }
    }

    /// Holds the graph between nodes and tool calls. Everything it knows stays; a resume re-reads the screen first.
    public func pause() {
        guard phase == .running else { return }
        write(["t": "pause"])
        phase = .paused
    }

    public func resume() {
        guard phase == .paused else { return }
        write(["t": "resume"])
        blockedReason = nil
        phase = .running
    }

    public func stop() {
        guard isRunning else { return }
        answerDevice(.deny)
        write(["t": "stop"])
        // The graph ends at its next checkpoint and reports; the process end settles the phase if it never does.
        Task { [weak self, weak handle] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.isRunning, self.handle === handle else { return }
            self.handle?.terminate()
        }
    }

    public func answerDevice(_ answer: DeviceAnswer) { handler.answer(answer) }

    /// A person's tap on the live view while the agent is paused: run directly, never asked about, and recorded as a human step.
    public func takeOverTap(at point: DevicePoint) async {
        guard phase == .paused || !isRunning else { return }
        let reply = await handler.runAsPerson(DeviceCommand(.tap, ["x": .number(point.x.rounded()), "y": .number(point.y.rounded())]))
        if !reply.ok { notice = reply.text }
    }

    /// A person's swipe on the live view, between two device points. Runs in order with the person's other input.
    public func takeOverSwipe(from: DevicePoint, to: DevicePoint) {
        flushTyping()
        enqueueHuman { [weak self] in
            await self?.runPerson(DeviceCommand(.swipe, ["x1": .number(from.x), "y1": .number(from.y), "x2": .number(to.x), "y2": .number(to.y), "seconds": .number(0.3)]))
        }
    }

    /// A person's scroll (mouse wheel or trackpad) on the live view: "down" shows content further down.
    public func takeOverScroll(_ direction: String) {
        flushTyping()
        enqueueHuman { [weak self] in await self?.runPerson(DeviceCommand(.scroll, ["direction": .string(direction)])) }
    }

    /// A special key typed on the Mac keyboard while the live view has focus: return, delete, escape, tab, space or an arrow.
    public func takeOverKey(_ key: String) {
        flushTyping()
        enqueueHuman { [weak self] in await self?.runPerson(DeviceCommand(.pressKey, ["key": .string(key)])) }
    }

    /// Characters typed on the Mac keyboard go to the simulator's focused field; quick typing is sent as one command.
    public func takeOverText(_ text: String) {
        typed += text
        typingFlush?.cancel()
        typingFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.flushTyping()
        }
    }

    private func flushTyping() {
        typingFlush?.cancel()
        guard !typed.isEmpty else { return }
        let text = String(typed.prefix(500))
        typed = ""
        enqueueHuman { [weak self] in await self?.runPerson(DeviceCommand(.typeText, ["text": .string(text)])) }
    }

    private func enqueueHuman(_ work: @escaping @MainActor () async -> Void) {
        let previous = humanQueue
        humanQueue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func runPerson(_ command: DeviceCommand) async {
        let reply = await handler.runAsPerson(command)
        if !reply.ok { notice = reply.text }
    }

    /// Saves what was done as a test case in the Tests section. Returns the key it was saved under.
    @discardableResult
    public func saveAsTestCase() -> String? {
        guard canSaveAsCase, let library else { return nil }
        let steps = OperationRecorder.steps(goals: goals, actions: recorded)
        guard !steps.isEmpty else { notice = "Nothing to save yet: no step was completed."; return nil }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let record = TestCaseRecord(key: "OPERATE-" + stamp.string(from: Date()), title: OperationRecorder.title(for: task), source: "operate", steps: steps, isEditable: true)
        guard let key = library.create(record) else { notice = library.errorMessage; return nil }
        savedCaseKey = key
        persist(status: phase == .finished(done: true) ? "done" : "failed")
        return key
    }

    // MARK: Sessions

    /// Shows an earlier task. Ignored while one is running.
    public func select(_ id: UUID) {
        guard !isRunning, let session = store?.load(id) else { return }
        activeSessionID = id
        started = session.startedAt
        task = session.task
        goals = session.goals
        entries = session.entries
        summary = session.summary
        usage = session.usage
        workerSeconds = session.workerSeconds ?? [:]
        recorded = session.recorded
        savedCaseKey = session.savedCaseKey
        highlight = nil
        blockedReason = nil
        notice = nil
        activeNode = ""
        activeAgent = ""
        phase = session.status == "running" ? .finished(done: false) : .finished(done: session.status == "done")
    }

    /// Clears the screen for a new task. Ignored while one is running.
    public func newSession() {
        guard !isRunning else { return }
        reset(task: "")
        activeSessionID = nil
        phase = .idle
    }

    public func deleteSession(_ id: UUID) {
        guard !(isRunning && id == activeSessionID) else { return }
        store?.delete(id)
        sessions = store?.list() ?? []
        if activeSessionID == id { newSession() }
    }

    private func persist(status: String) {
        guard let store, let id = activeSessionID else { return }
        store.save(OperateSession(id: id, task: task, startedAt: started, status: status, goals: goals, entries: entries, summary: summary, usage: usage,
                                  recorded: recorded, savedCaseKey: savedCaseKey, workerSeconds: workerSeconds))
        sessions = store.list()
    }

    // MARK: Events

    func consume(_ line: String) {
        guard line.hasPrefix("@@EVENT "), let data = line.dropFirst(8).data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = event["t"] as? String else { return }
        let agent = event["agent"] as? String ?? ""
        switch type {
        case "agent-ready": modelName = event["model"] as? String ?? ""
        case "graph-hierarchy":
            team = (event["leads"] as? [[String: Any]] ?? []).map { OperateLead(name: $0["lead"] as? String ?? "", workers: $0["workers"] as? [String] ?? []) }
        case "graph-plan":
            goals = (event["goals"] as? [[String: Any]] ?? []).compactMap(Self.goal)
            if let current = currentGoal, !goals.contains(where: { $0.number == current }) { currentGoal = nil }
        case "graph-node":
            let name = event["name"] as? String ?? ""
            let goal = event["goal"] as? Int
            if event["state"] as? String == "exit", let ms = event["ms"] as? Int { workerSeconds[Self.workerName(for: name), default: 0] += Double(ms) / 1000 }
            if event["state"] as? String == "enter" {
                activeNode = name
                currentGoal = goal ?? currentGoal
                markActive(goal)
                entries.append(OperateEntry(kind: .node, agent: name, text: Self.nodeTitle(name), goal: currentGoal ?? 0))
            }
        case "agent-start": activeAgent = agent
        case "agent-think": stream(.thought, agent: agent, delta: event["delta"] as? String ?? "")
        case "agent-text": stream(.text, agent: agent, delta: event["delta"] as? String ?? "")
        case "agent-tool":
            closeOpen()
            var entry = OperateEntry(kind: .tool, agent: agent, text: event["name"] as? String ?? "", args: event["args"] as? String ?? "", goal: currentGoal ?? 0)
            entry.callID = event["id"] as? String ?? ""
            entries.append(entry)
        case "agent-tool-result":
            if let index = entries.lastIndex(where: { $0.kind == .tool && $0.callID == (event["id"] as? String ?? "") }) {
                entries[index].succeeded = event["ok"] as? Bool ?? true
                entries[index].summary = event["summary"] as? String ?? ""
                entries[index].milliseconds = event["ms"] as? Int
            }
        case "agent-device-request": handleDevice(event)
        case "agent-error":
            closeOpen()
            entries.append(OperateEntry(kind: .error, agent: "", text: event["message"] as? String ?? "The agents stopped.", goal: currentGoal ?? 0))
            // The agent process stays up for the next task, but this one is over: do not leave it looking busy.
            if isRunning {
                phase = .finished(done: false)
                activeNode = ""
                activeAgent = ""
                blockedReason = nil
                persist(status: "failed")
            }
        case "operate-blocked":
            blockedReason = event["reason"] as? String ?? "The screen needs you."
            if phase == .running { phase = .paused }
        case "operate-start": task = event["task"] as? String ?? task
        case "operate-usage":
            usage = OperateUsage(seconds: event["seconds"] as? Int ?? 0, calls: event["calls"] as? Int ?? 0, input: event["input"] as? Int ?? 0,
                                 output: event["output"] as? Int ?? 0, cached: event["cached"] as? Int ?? 0)
            if !isRunning, activeSessionID != nil, case .finished(let done) = phase { persist(status: done ? "done" : "failed") }
        case "operate-final":
            closeOpen()
            goals = (event["goals"] as? [[String: Any]] ?? []).compactMap(Self.goal)
            summary = event["summary"] as? String ?? ""
            let status = event["status"] as? String ?? ""
            blockedReason = nil
            phase = .finished(done: status == "done")
            activeNode = ""
            activeAgent = ""
            currentGoal = nil
            persist(status: status == "done" ? "done" : status == "stopped" ? "stopped" : "failed")
        default: break
        }
    }

    private func handleDevice(_ event: [String: Any]) {
        let id = event["id"] as? String ?? ""
        Task {
            let reply = await self.handler.handle(event)
            if let point = reply.point { self.highlight = OperateHighlight(point: point, byPerson: false, at: Date()) }
            self.write(["t": "device-result", "id": id, "ok": reply.ok, "text": reply.ok ? reply.text : "FAILED: " + reply.text, "file": reply.file ?? ""])
        }
    }

    private func executed(_ execution: DeviceExecution) {
        if execution.byPerson, let point = execution.point { highlight = OperateHighlight(point: point, byPerson: true, at: Date()) }
        if let action = OperationRecorder.action(for: execution, goal: execution.byPerson ? nil : currentGoal) { recorded.append(action) }
    }

    private func processEnded(_ run: any CaseRunHandle) {
        guard handle === run else { return }
        handle = nil
        if isRunning {
            entries.append(OperateEntry(kind: .error, agent: "", text: "The agent process ended before it finished."))
            phase = .finished(done: false)
            persist(status: "failed")
        }
        answerDevice(.deny)
        activeNode = ""
        activeAgent = ""
    }

    // MARK: Helpers

    private func reset(task: String) {
        self.task = task
        goals = []
        entries = []
        summary = ""
        usage = OperateUsage()
        workerSeconds = [:]
        recorded = []
        savedCaseKey = nil
        highlight = nil
        notice = nil
        blockedReason = nil
        currentGoal = nil
        started = Date()
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) else { return }
        handle?.send(line)
    }

    private func markActive(_ number: Int?) {
        guard let number else { return }
        for index in goals.indices where goals[index].state == .pending || goals[index].state == .active {
            goals[index].state = goals[index].number == number ? .active : .pending
        }
    }

    private func stream(_ kind: OperateEntry.Kind, agent: String, delta: String) {
        guard !delta.isEmpty else { return }
        if let last = entries.last, last.kind == kind, last.agent == agent, last.isOpen {
            entries[entries.count - 1].text += delta
        } else {
            var entry = OperateEntry(kind: kind, agent: agent, text: delta, goal: currentGoal ?? 0)
            entry.isOpen = true
            entries.append(entry)
        }
    }

    private func closeOpen() {
        if let last = entries.last, last.isOpen { entries[entries.count - 1].isOpen = false }
    }

    static func goal(_ item: [String: Any]) -> OperateGoal? {
        guard let number = item["number"] as? Int else { return nil }
        return OperateGoal(number: number, text: item["text"] as? String ?? "", kind: item["kind"] as? String ?? "", state: OperateGoal.State(rawValue: item["state"] as? String ?? "") ?? .pending,
                           attempts: item["attempts"] as? Int ?? 0, expected: item["expected"] as? String ?? "")
    }

    /// Which part of the team a graph node belongs to, for the time breakdown.
    public static func workerName(for node: String) -> String {
        switch node {
        case "plan", "replan": "Orchestrator"
        case "navigate": "Navigator"
        case "configure": "Configurator"
        case "inspect": "Inspector"
        case "verify": "Verifier"
        default: "Screen reads"
        }
    }

    /// The breakdown as "Verifier 22 s · Orchestrator 15 s", largest first, parts under a second left out.
    public var workerTimeSummary: String {
        workerSeconds.filter { $0.value >= 1 }.sorted { $0.value > $1.value }.map { "\($0.key) \(Int($0.value.rounded())) s" }.joined(separator: " · ")
    }

    public static func nodeTitle(_ node: String) -> String {
        switch node {
        case "observe_start", "observe", "observe_after": "Reading the screen"
        case "plan": "Planning the goals"
        case "select": "Choosing the next goal"
        case "replan": "Re-planning after a failed goal"
        case "navigate": "Operating the screen"
        case "configure": "Setting the device up"
        case "inspect": "Looking at the screen"
        case "verify": "Checking the goal"
        case "report": "Writing the result"
        default: node
        }
    }
}
