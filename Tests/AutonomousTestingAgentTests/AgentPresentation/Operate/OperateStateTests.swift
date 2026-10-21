import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

private final class OperateProcess: CaseRunHandle, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var sentLines: [String] = []
    var sent: [String] { lock.withLock { sentLines } }
    init() {
        var captured: AsyncStream<String>.Continuation!
        lines = AsyncStream { captured = $0 }
        continuation = captured
    }
    func send(_ line: String) { lock.withLock { sentLines.append(line) } }
    func terminate() { continuation.finish() }
}

private final class OperateLauncher: CaseRunLaunching, @unchecked Sendable {
    let process = OperateProcess()
    private let lock = NSLock()
    private var lists: [[String]] = []
    var arguments: [[String]] { lock.withLock { lists } }
    func launch(arguments: [String]) throws -> any CaseRunHandle { lock.withLock { lists.append(arguments) }; return process }
}

private actor OperateDevice: DeviceControlling {
    private(set) var ran: [DeviceCommand] = []
    private let booted = DeviceTarget(udid: "SIM-1", name: "iPhone 17", kind: .simulator, state: "Booted", osVersion: "iOS 26.5")
    func targets() async throws -> [DeviceTarget] { [booted] }
    func defaultTarget() async -> DeviceTarget? { booted }
    func run(_ command: DeviceCommand, on target: DeviceTarget, context: DeviceValidationContext) async throws -> DeviceCommandResult {
        ran.append(command)
        switch command.kind {
        case .tap: return DeviceCommandResult(text: "Tapped “Search” at (200, 90).", pointX: command.number("x") ?? 200, pointY: command.number("y") ?? 90)
        default: return DeviceCommandResult(text: "did \(command.kind.rawValue)")
        }
    }
}

private final class MemoryStore: TestCaseLibraryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [TestCaseRecord] = []
    var records: [TestCaseRecord] { lock.withLock { saved } }
    func all() -> [TestCaseRecord] { records }
    func save(_ record: TestCaseRecord, isNew: Bool) throws { lock.withLock { saved.append(record) } }
    func delete(key: String) throws {}
    func duplicate(key: String, as newKey: String) throws {}
    func normalizedKey(_ raw: String) -> String? { raw.isEmpty ? nil : raw.uppercased() }
    func fileURL(key: String) -> URL? { nil }
}

private func event(_ fields: [String: Any]) -> String {
    "@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
}

@Suite("Screen mapping")
struct ScreenMappingTests {
    @Test("A click maps to a device point and back; outside the picture it maps to nothing")
    func roundTrip() throws {
        // A 1206x2622 picture (402x874 points at 3x) in a 300-wide view.
        let mapping = ScreenMapping(viewSize: CGSize(width: 300, height: 700), pixelSize: CGSize(width: 1206, height: 2622))
        #expect(mapping.deviceSize == CGSize(width: 402, height: 874))
        let rect = mapping.imageRect
        let center = try #require(mapping.devicePoint(forViewPoint: CGPoint(x: rect.midX, y: rect.midY)))
        #expect(center == DevicePoint(x: 201, y: 437))
        let back = mapping.viewPoint(forDevice: center)
        #expect(abs(back.x - rect.midX) < 1 && abs(back.y - rect.midY) < 1)
        #expect(mapping.devicePoint(forViewPoint: CGPoint(x: -5, y: 10)) == nil)
        #expect(mapping.devicePoint(forViewPoint: CGPoint(x: rect.minX + 1, y: rect.minY + 1)) == DevicePoint(x: 1, y: 1))
    }

    @Test("A wide view letterboxes the picture")
    func letterbox() {
        let mapping = ScreenMapping(viewSize: CGSize(width: 600, height: 400), pixelSize: CGSize(width: 750, height: 1334))
        #expect(mapping.scale == 2)
        #expect(mapping.imageRect.width < 600 && mapping.imageRect.minX > 100)
        #expect(mapping.devicePoint(forViewPoint: CGPoint(x: 10, y: 200)) == nil)
    }
}

@Suite("Operation recorder")
struct OperationRecorderTests {
    private func execution(_ command: DeviceCommand, text: String = "", byPerson: Bool = false) -> DeviceExecution {
        DeviceExecution(command: command, phrase: DeviceCommandCatalog.phrase(command), resultText: text, ok: true, point: nil, byPerson: byPerson)
    }

    @Test("A tap is recorded by the label it hit, not its coordinates")
    func label() {
        let action = OperationRecorder.action(for: execution(DeviceCommand(.tap, ["handle": .string("#4")]), text: "Tapped #4 “Search” at (200, 90)."), goal: 2)
        #expect(action?.text == "Tap “Search”" && action?.goal == 2)
        let typed = OperationRecorder.action(for: execution(DeviceCommand(.tap, ["label": .string("Done")])), goal: 1)
        #expect(typed?.text == "Tap “Done”")
    }

    @Test("A failed command is not recorded")
    func failed() {
        let failed = DeviceExecution(command: DeviceCommand(.tap, [:]), phrase: "", resultText: "", ok: false, point: nil, byPerson: false)
        #expect(OperationRecorder.action(for: failed, goal: 1) == nil)
    }

    @Test("Steps follow the goals that passed, with the actions as data, and human steps come last")
    func steps() {
        let goals = [
            OperateGoal(number: 1, text: "Open Settings", kind: "navigate", state: .done, attempts: 1, expected: "Settings is open"),
            OperateGoal(number: 2, text: "Turn on dark mode", kind: "configure", state: .failed, attempts: 3, expected: ""),
            OperateGoal(number: 3, text: "Check the title", kind: "verify", state: .done, attempts: 1, expected: "The title reads Settings"),
        ]
        let actions = [RecordedAction(goal: 1, text: "Open the app com.apple.Preferences", byPerson: false), RecordedAction(goal: 2, text: "Tap “Dark”", byPerson: false),
                       RecordedAction(goal: nil, text: "Tap “Back”", byPerson: true)]
        let steps = OperationRecorder.steps(goals: goals, actions: actions)
        #expect(steps.map(\.action) == ["Open Settings", "Check the title", "Tap “Back”"])
        #expect(steps[0].data == "Open the app com.apple.Preferences" && steps[0].expected == "Settings is open")
    }

    @Test("A long task makes a short title")
    func title() {
        #expect(OperationRecorder.title(for: "Do a thing\nthen another") == "Do a thing")
        #expect(OperationRecorder.title(for: String(repeating: "a", count: 200)).count == 78)
    }
}

@MainActor
@Suite("Operate state")
struct OperateStateTests {
    private let launcher = OperateLauncher()
    private let device = OperateDevice()
    private let store = MemoryStore()

    private func make(sessions: OperateSessionStore? = nil) -> OperateState {
        let defaults = UserDefaults(suiteName: "operate-\(UUID().uuidString)")!
        let handler = DeviceRequestHandler(control: device, projectRoot: FileManager.default.temporaryDirectory)
        return OperateState(launcher: launcher, handler: handler, library: TestLibraryState(store: store), defaults: defaults, store: sessions)
    }

    private func sent(_ type: String) -> [[String: Any]] {
        launcher.process.sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }.filter { $0["t"] as? String == type }
    }

    private func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<150 { if condition() { return }; try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test("Starting launches the operate process with the task and never a repository, and an empty task does nothing")
    func start() {
        let state = make()
        state.start("   ")
        #expect(launcher.arguments.isEmpty && state.phase == .idle)
        state.start("Open Safari")
        #expect(launcher.arguments.first == ["--operate", "--events", "--provider=deepseek", "--task=Open Safari"])
        #expect(state.phase == .running && state.isRunning)
    }

    @Test("The plan, the active node and the result follow the graph events")
    func events() {
        let state = make()
        state.start("task")
        state.consume(event(["t": "graph-hierarchy", "leads": [["lead": "Action lead", "workers": ["Navigator", "Configurator"]]]]))
        state.consume(event(["t": "graph-plan", "goals": [["number": 1, "text": "Open Settings", "kind": "navigate", "state": "pending", "attempts": 0, "expected": "x"],
                                                          ["number": 2, "text": "Check", "kind": "verify", "state": "pending", "attempts": 0, "expected": "y"]]]))
        state.consume(event(["t": "graph-node", "name": "navigate", "kind": "agent", "state": "enter", "step": 3, "goal": 1]))
        #expect(state.team == [OperateLead(name: "Action lead", workers: ["Navigator", "Configurator"])])
        #expect(state.goals.map(\.state) == [.active, .pending] && state.activeNode == "navigate")
        state.consume(event(["t": "agent-tool", "agent": "Navigator", "id": "1", "name": "tap", "args": "{}"]))
        state.consume(event(["t": "agent-tool-result", "id": "1", "ok": true, "summary": "Tapped"]))
        #expect(state.entries.last?.succeeded == true && state.entries.last?.summary == "Tapped")
        state.consume(event(["t": "operate-usage", "seconds": 12, "calls": 5, "input": 100, "output": 20, "cached": 0]))
        state.consume(event(["t": "operate-final", "status": "done", "summary": "ok", "goals": [["number": 1, "text": "Open Settings", "kind": "navigate", "state": "done", "attempts": 1, "expected": "x"]]]))
        #expect(state.phase == .finished(done: true) && state.summary == "ok" && state.usage.calls == 5 && state.activeNode.isEmpty)
    }

    @Test("Pause and resume are sent to the process and kept in the phase; only a running task pauses")
    func pauseResume() {
        let state = make()
        state.pause()
        #expect(sent("pause").isEmpty)
        state.start("task")
        state.pause()
        #expect(state.isPaused && sent("pause").count == 1)
        state.resume()
        #expect(state.phase == .running && sent("resume").count == 1)
        state.stop()
        #expect(sent("stop").count == 1)
    }

    @Test("A reversible device request from the graph is allowed by the task grant, runs, rings the highlight and is recorded under its goal")
    func deviceRequest() async {
        let state = make()
        state.start("task")
        state.consume(event(["t": "graph-plan", "goals": [["number": 1, "text": "Open search", "kind": "navigate", "state": "pending", "attempts": 0, "expected": ""]]]))
        state.consume(event(["t": "graph-node", "name": "navigate", "state": "enter", "goal": 1]))
        state.consume(event(["t": "agent-device-request", "id": "r1", "command": ["kind": "tap", "arguments": ["x": 200, "y": 90]]]))
        await wait { !self.sent("device-result").isEmpty }
        #expect(sent("device-result").first?["ok"] as? Bool == true && state.deviceApproval == nil)
        #expect(state.highlight?.point == DevicePoint(x: 200, y: 90) && state.highlight?.byPerson == false)
        #expect(state.recorded == [RecordedAction(goal: 1, text: "Tap “Search”", byPerson: false)])
    }

    @Test("Without the task grant a reversible command asks; denying refuses it")
    func asks() async {
        let state = make()
        state.letAgentOperate = false
        state.start("task")
        state.consume(event(["t": "agent-device-request", "id": "r1", "command": ["kind": "press_button", "arguments": ["button": "HOME"]]]))
        await wait { state.deviceApproval != nil }
        #expect(state.deviceApproval?.id == "r1" && state.isWaitingForPerson)
        state.answerDevice(.deny)
        await wait { !self.sent("device-result").isEmpty }
        #expect((sent("device-result").first?["text"] as? String)?.hasPrefix("FAILED:") == true)
        let ran = await device.ran.count
        #expect(ran == 0)
    }

    @Test("A person's tap while paused runs without a question and is recorded as a human step")
    func takeOver() async {
        let state = make()
        state.letAgentOperate = false
        state.start("task")
        state.pause()
        await state.takeOverTap(at: DevicePoint(x: 120, y: 300))
        #expect(state.deviceApproval == nil)
        #expect(state.highlight?.byPerson == true)
        #expect(state.recorded == [RecordedAction(goal: nil, text: "Tap “Search”", byPerson: true)])
        let ran = await device.ran
        #expect(ran.count == 1 && ran.first?.kind == .tap)
    }

    @Test("A finished session is saved as a case in the Tests section, once")
    func save() async {
        let state = make()
        state.start("Open apple.com in Safari")
        let goal: [String: Any] = ["number": 1, "text": "Open apple.com", "kind": "navigate", "state": "pending", "attempts": 0, "expected": "apple.com is shown"]
        state.consume(event(["t": "graph-plan", "goals": [goal]]))
        state.consume(event(["t": "graph-node", "name": "navigate", "state": "enter", "goal": 1]))
        #expect(!state.canSaveAsCase)
        state.consume(event(["t": "agent-device-request", "id": "r1", "command": ["kind": "tap", "arguments": ["x": 10, "y": 20]]]))
        await wait { !self.sent("device-result").isEmpty }
        #expect(state.saveAsTestCase() == nil, "not while it is running")
        var done = goal; done["state"] = "done"
        state.consume(event(["t": "operate-final", "status": "done", "summary": "", "goals": [done]]))
        #expect(state.canSaveAsCase)
        let key = state.saveAsTestCase()
        #expect(key?.hasPrefix("OPERATE-") == true && state.savedCaseKey == key)
        let record = store.records.first
        #expect(record?.title == "Open apple.com in Safari" && record?.source == "operate")
        #expect(record?.steps.map(\.action) == ["Open apple.com"] && record?.steps.first?.data == "Tap “Search”" && record?.steps.first?.expected == "apple.com is shown")
        #expect(!state.canSaveAsCase && state.saveAsTestCase() == nil)
    }

    @Test("When the agents need the person the task is paused with the reason, and resuming clears it")
    func blocked() {
        let state = make()
        state.start("task")
        state.consume(event(["t": "operate-blocked", "reason": "Log in with your account."]))
        #expect(state.isPaused && state.blockedReason == "Log in with your account.")
        state.resume()
        #expect(state.phase == .running && state.blockedReason == nil)
    }

    @Test("A person's swipe, scroll, keys and typing while paused reach the device in order, and quick typing is one command")
    func takeOverInput() async {
        let state = make()
        state.start("task")
        state.pause()
        state.takeOverSwipe(from: DevicePoint(x: 200, y: 600), to: DevicePoint(x: 200, y: 200))
        state.takeOverScroll("down")
        state.takeOverText("he")
        state.takeOverText("llo")
        state.takeOverKey("return")
        for _ in 0..<150 { if await device.ran.count >= 4 { break }; try? await Task.sleep(nanoseconds: 20_000_000) }
        let ran = await device.ran
        #expect(ran.map(\.kind) == [.swipe, .scroll, .typeText, .pressKey])
        #expect(ran[2].string("text") == "hello" && ran[3].string("key") == "return")
        #expect(state.recorded.map(\.text).first == "Swipe up")
        let allHuman = state.recorded.allSatisfy { $0.byPerson }
        #expect(allHuman)
    }

    @Test("Sessions are saved, listed newest first, can be opened again and deleted")
    func sessionsPersist() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("operate-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = make(sessions: OperateSessionStore(directory: folder))
        state.start("Open apple.com")
        #expect(state.sessions.count == 1 && state.sessions[0].status == "running")
        let goal: [String: Any] = ["number": 1, "text": "Open apple.com", "kind": "navigate", "state": "done", "attempts": 1, "expected": "x"]
        state.consume(event(["t": "operate-final", "status": "done", "summary": "ok", "goals": [goal]]))
        #expect(state.sessions[0].status == "done")

        let again = make(sessions: OperateSessionStore(directory: folder))
        #expect(again.sessions.map(\.task) == ["Open apple.com"])
        again.select(again.sessions[0].id)
        #expect(again.task == "Open apple.com" && again.goals.count == 1 && again.summary == "ok" && again.phase == .finished(done: true))
        again.newSession()
        #expect(again.phase == .idle && again.goals.isEmpty)
        again.deleteSession(again.sessions[0].id)
        #expect(again.sessions.isEmpty)
    }

    @Test("The result is read as findings, goals that did not pass, and plain text for copying")
    func resultReport() {
        let state = make()
        state.start("Find the heading")
        let summary = "✓ 1. Open Safari — done\n✗ 2. Read the heading (The screen shows a login)\nFound: HomeView | Second answer"
        let goals: [[String: Any]] = [["number": 1, "text": "Open Safari", "kind": "navigate", "state": "done", "attempts": 1, "expected": ""],
                                      ["number": 2, "text": "Read the heading", "kind": "inspect", "state": "failed", "attempts": 3, "expected": ""]]
        state.consume(event(["t": "operate-final", "status": "failed", "summary": summary, "goals": goals]))
        #expect(state.findings == ["HomeView", "Second answer"])
        #expect(state.unmetGoals == ["2. Read the heading (The screen shows a login)"])
        let text = state.resultText
        #expect(text.contains("Outcome: not finished") && text.contains("- [x] Open Safari") && text.contains("- [ ] Read the heading") && text.contains("Found: HomeView; Second answer"))
    }

    @Test("An error from the agents ends the task as not finished, so it never keeps looking busy")
    func agentError() {
        let state = make()
        state.start("task")
        state.consume(event(["t": "agent-error", "message": "The model did not answer in time."]))
        #expect(state.phase == .finished(done: false) && !state.isRunning && state.entries.last?.text == "The model did not answer in time.")
    }

    @Test("The graph's node timings add up per part of the team, largest first, and survive a saved session")
    func workerTime() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("operate-time-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = make(sessions: OperateSessionStore(directory: folder))
        state.start("task")
        for (name, ms) in [("plan", 15_000), ("verify", 12_000), ("verify", 10_000), ("navigate", 9_400), ("observe", 600), ("observe_after", 500)] {
            state.consume(event(["t": "graph-node", "name": name, "kind": "agent", "state": "exit", "step": 1, "goal": 1, "ms": ms]))
        }
        #expect(state.workerTimeSummary == "Verifier 22 s · Orchestrator 15 s · Navigator 9 s · Screen reads 1 s")
        state.consume(event(["t": "operate-final", "status": "done", "summary": "", "goals": []]))
        let again = make(sessions: OperateSessionStore(directory: folder))
        again.select(again.sessions[0].id)
        #expect(again.workerSeconds["Verifier"] == 22)
    }

    @Test("A process that ends while running is reported, not left running")
    func ended() async {
        let state = make()
        state.start("task")
        launcher.process.terminate()
        await wait { !state.isRunning }
        #expect(state.phase == .finished(done: false) && state.entries.last?.kind == .error)
    }
}

@Suite("Operate goal cards")
struct OperateGoalCardTests {
    private func tool(_ name: String, _ args: String, goal: Int, ok: Bool? = true, summary: String = "") -> OperateEntry {
        var entry = OperateEntry(kind: .tool, agent: "Navigator", text: name, args: args, goal: goal)
        entry.succeeded = ok
        entry.summary = summary
        return entry
    }

    private let goals = [OperateGoal(number: 1, text: "Open Settings", kind: "navigate", state: .done, attempts: 1, expected: "Settings"),
                         OperateGoal(number: 2, text: "Turn on dark mode", kind: "configure", state: .failed, attempts: 3, expected: "")]

    @Test("Actions become readable lines under their goal, and the plan payload and budget notices never show")
    func lines() {
        let entries = [
            tool("set_plan", #"{"goals":[{"text":"x"}]}"#, goal: 0),
            tool("device_input", ##"{"command":"tap","handle":"#4"}"##, goal: 1, summary: "Tapped #4 “Search” at (200, 90)."),
            tool("device_observe", #"{"command":"read_screen","mode":"state"}"#, goal: 1, summary: "Tool budget spent (3 calls)."),
            tool("device_observe", #"{"command":"look","question":"Is it dark?"}"#, goal: 2),
        ]
        let cards = OperateCards.build(goals: goals, entries: entries)
        #expect(cards.map(\.id) == [1, 2], "nothing before the plan, so no getting-ready card")
        #expect(cards[0].lines.map(\.text) == ["Tapped “Search”", "Read the screen"])
        #expect(cards[1].lines.map(\.text) == ["Looked at the picture: Is it dark?"])
        #expect(!cards.flatMap(\.lines).contains { $0.text.contains("{") || $0.text.contains("budget") })
    }

    @Test("A verdict becomes the card's evidence with its outcome, and a swipe is described by direction")
    func verdicts() {
        let entries = [
            tool("device_input", #"{"command":"swipe","x1":200,"y1":600,"x2":200,"y2":200}"#, goal: 2),
            tool("report_verdict", #"{"passed":false,"evidence":"The screen is still light."}"#, goal: 2),
        ]
        let card = OperateCards.build(goals: goals, entries: entries)[1]
        #expect(card.evidence == "The screen is still light." && card.evidencePassed == false)
        #expect(card.lines.first?.text == "Swiped up")
    }

    @Test("What happens before there is a plan is its own card, and thoughts are kept apart as reasoning")
    func gettingReady() {
        var thought = OperateEntry(kind: .thought, agent: "Orchestrator", text: "I should open Settings.", goal: 1)
        thought.isOpen = false
        let before = tool("device_observe", #"{"command":"read_screen"}"#, goal: 0)
        let cards = OperateCards.build(goals: goals, entries: [before, thought])
        #expect(cards.first?.id == 0 && cards.first?.title == "Getting ready")
        #expect(cards[1].reasoning == "I should open Settings." && cards[1].lines.isEmpty)
    }

    @Test("A failed command shows as failed and an old saved entry still decodes")
    func failedAndOld() throws {
        let failed = tool("device_input", #"{"command":"tap","label":"Done"}"#, goal: 1, ok: false, summary: "FAILED: no match")
        #expect(OperateCards.line(for: failed)?.outcome == .failed && OperateCards.line(for: failed)?.text == "Tapped “Done”")
        let old = #"{"kind":"tool","agent":"Navigator","text":"device_input","detail":"x","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#
        let entry = try JSONDecoder().decode(OperateEntry.self, from: Data(old.utf8))
        #expect(entry.text == "device_input" && entry.goal == 0)
    }
}

