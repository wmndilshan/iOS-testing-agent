import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

private final class FakeRun: CaseRunHandle, @unchecked Sendable {
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

    func emit(_ line: String) { continuation.yield(line) }
    func finish() { continuation.finish() }
    func send(_ line: String) { lock.withLock { sentLines.append(line) } }
    func terminate() { continuation.finish() }
}

private struct FakeLauncher: CaseRunLaunching {
    let run: FakeRun
    func launch(arguments: [String]) throws -> any CaseRunHandle { run }
}

@MainActor
@Suite("Case run state")
struct CaseRunStateTests {
    private func state(_ run: FakeRun = FakeRun()) -> (CaseRunState, FakeRun) {
        (CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: FakeLauncher(run: run)), run)
    }

    private func event(_ fields: [String: Any]) -> String {
        "@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test("A case event lists its steps, and rows decide each step's tick or cross")
    func testStepStatuses() {
        let (run, _) = state()
        run.consume(event(["t": "case", "title": "Demo", "steps": [["number": 1, "text": "Open"], ["number": 2, "text": "Search"], ["number": 3, "text": "Shoot"]]]))
        run.consume(event(["t": "row", "id": "1.a", "number": 1, "intent": "Tap", "action": "tap", "status": "passed", "detail": "ok"]))
        run.consume(event(["t": "row", "id": "2.a", "number": 2, "intent": "Type", "action": "typeText", "status": "failed", "detail": "target not found"]))
        #expect(run.steps.map(\.status) == [.passed, .failed, .pending])
        #expect(run.steps[1].failureReason == "target not found")
        #expect(run.title == "Demo")
    }

    @Test("A later row for the same action replaces the earlier one instead of adding a duplicate")
    func testRowUpdate() {
        let (run, _) = state()
        run.consume(event(["t": "case", "title": "T", "steps": [["number": 1, "text": "Open"]]]))
        run.consume(event(["t": "row", "id": "1.a", "number": 1, "intent": "Tap", "action": "tap", "status": "running", "detail": ""]))
        run.consume(event(["t": "row", "id": "1.a", "number": 1, "intent": "Tap", "action": "tap", "status": "passed", "detail": "ok"]))
        #expect(run.steps[0].actions.count == 1)
        #expect(run.steps[0].status == .passed)
    }

    @Test("Planner thoughts are kept per step, and ordinary lines go to the log")
    func testThoughtsAndLog() {
        let (run, _) = state()
        run.consume(event(["t": "think", "step": 2, "phase": "a1", "text": "Planned: tap Search"]))
        run.consume("RESULT ✓ PASS 1.a (step 1): fine")
        #expect(run.thoughts.map(\.text) == ["Planned: tap Search"])
        #expect(run.log == ["RESULT ✓ PASS 1.a (step 1): fine"])
    }

    @Test("A choice carries its options, the agent's guidance is shown, and a message to the agent goes out as a note")
    func guidanceAndChoices() {
        let (run, fake) = state()
        run.start(key: "x-1")
        run.consume(event(["t": "prompt", "id": "conflict-12", "kind": "choice", "title": "“Test1” already exists", "message": "m", "secure": false,
                           "options": ["Use Test2 instead of Test1", "Skip this step"], "timeout": 600]))
        #expect(run.prompt?.options == ["Use Test2 instead of Test1", "Skip this step"] && run.prompt?.isWaitOnly == false)
        run.answer("Use Test2 instead of Test1")
        #expect(fake.sent == ["Use Test2 instead of Test1"])
        run.consume(event(["t": "guidance", "text": "Test1 → Test2", "heard": "Test1 → Test2"]))
        #expect(run.guidance == "Test1 → Test2" && run.thoughts.last?.text == "Guidance: Test1 → Test2")
        run.tell("keep the Table view\nand never tap Save")
        #expect(fake.sent.last == "@@NOTE keep the Table view and never tap Save")
    }

    @Test("Instructions typed before a run become one note flag per sentence; clearing is a flag too")
    func noteFlags() {
        #expect(CaseRunState.noteFlags("use Test2 instead of Test1; keep the Table view\n\n") == ["--note=use Test2 instead of Test1", "--note=keep the Table view"])
        #expect(CaseRunState.noteFlags("   ").isEmpty)
    }

    @Test("A password prompt is answered on the run's input and then clears; the answer is never logged")
    func testPromptAnswer() async {
        let (run, fake) = state()
        run.start(key: "x-1")
        run.consume(event(["t": "prompt", "id": "password", "kind": "password", "title": "Password", "message": "m", "secure": true]))
        #expect(run.prompt?.secure == true)
        run.answer("s3cret-value")
        #expect(fake.sent == ["s3cret-value"])
        #expect(run.prompt == nil)
        #expect(!run.log.contains { $0.contains("s3cret-value") })
        fake.finish()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(run.isRunning == false)
    }

    @Test("Starting uppercases the key, adds the allow-destructive flag only for full autonomy, and ignores a second start")
    func testStartArguments() {
        let fake = FakeRun()
        final class Recorder: CaseRunLaunching, @unchecked Sendable {
            let run: FakeRun; var arguments: [[String]] = []
            init(_ run: FakeRun) { self.run = run }
            func launch(arguments: [String]) throws -> any CaseRunHandle { self.arguments.append(arguments); return run }
        }
        let recorder = Recorder(fake)
        let run = CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: recorder)
        run.start(key: " DEMO-TC-1 ")
        run.start(key: "other")
        #expect(recorder.arguments.count == 1)
        #expect(recorder.arguments[0].contains("--run-case=DEMO-TC-1"))
        #expect(!recorder.arguments[0].contains("--allow-destructive"))
        #expect(recorder.arguments[0].contains("--events"))
    }

    @Test("Cases on disk are listed from TestCases and the AIO cache")
    func testAvailableCases() throws {
        let root = ProductFixtures.tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("TestCases"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Scripts/AIO/generated"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("TestCases/SAFARI-1.json"))
        try Data().write(to: root.appendingPathComponent("Scripts/AIO/generated/DEMO-TC-1.md"))
        try Data().write(to: root.appendingPathComponent("Scripts/AIO/generated/DEMO-TC-1_detail.json"))
        let run = CaseRunState(projectRoot: root, launcher: FakeLauncher(run: FakeRun()))
        #expect(run.availableCaseKeys() == ["DEMO-TC-1", "SAFARI-1"])
    }
}

@MainActor
@Suite("Run passes the repository")
struct CaseRunRepositoryFlagTests {
    private final class Recorder: CaseRunLaunching, @unchecked Sendable {
        var arguments: [[String]] = []
        func launch(arguments: [String]) throws -> any CaseRunHandle {
            self.arguments.append(arguments)
            throw NSError(domain: "test", code: 1)
        }
    }

    @Test("A usable repository is handed to the runner; none, or a missing folder, is not")
    func flag() {
        let folder = ProductFixtures.tempDir()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let withRepo = Recorder()
        CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: withRepo, repositoryPath: { folder.path }).start(key: "A-1")
        #expect(withRepo.arguments.first?.contains("--repo=\(folder.path)") == true)

        for path in ["", "/no/such/folder"] {
            let without = Recorder()
            CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: without, repositoryPath: { path }).start(key: "A-1")
            #expect(without.arguments.first?.contains { $0.hasPrefix("--repo=") } == false)
        }
    }
}

@MainActor
@Suite("Continue a run that stopped")
struct CaseRunResumeTests {
    private final class Recorder: CaseRunLaunching, @unchecked Sendable {
        var arguments: [[String]] = []
        func launch(arguments: [String]) throws -> any CaseRunHandle {
            self.arguments.append(arguments)
            return FakeRun()
        }
    }

    private func event(_ fields: [String: Any]) -> String {
        "@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    private let steps: [[String: Any]] = (1...4).map { ["number": $0, "text": "Step \($0)"] }

    /// A run of four steps that passed 1 and 2, failed 3 and never reached 4, now finished.
    private func stoppedRun(_ recorder: Recorder) -> CaseRunState {
        let run = CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: recorder)
        run.start(key: "k-1", bundleID: "com.apple.mobilesafari")
        run.consume(event(["t": "case", "title": "T", "steps": steps]))
        for (number, status) in [(1, "passed"), (2, "passed"), (3, "failed")] {
            run.consume(event(["t": "row", "id": "\(number).a", "number": number, "intent": "i", "action": "tap", "status": status, "detail": status == "failed" ? "not found" : "ok"]))
        }
        run.consume(event(["t": "done", "outcome": "FAILED", "failedStep": 3, "resumable": true]))
        run.stop()
        return run
    }

    @Test("A finished run that names its failed step can be resumed; a passed or unnamed one cannot")
    func canResume() async throws {
        let recorder = Recorder()
        let run = stoppedRun(recorder)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(run.failedStep == 3 && run.canResume)

        let passed = CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: Recorder())
        passed.consume(event(["t": "done", "outcome": "PASSED", "failedStep": 0]))
        #expect(passed.failedStep == nil && !passed.canResume)
    }

    @Test("Resume starts at the failed step with the same app, and keeps the results before it")
    func resume() async throws {
        let recorder = Recorder()
        let run = stoppedRun(recorder)
        try await Task.sleep(nanoseconds: 200_000_000)
        run.resume()

        let arguments = try #require(recorder.arguments.last)
        #expect(arguments.contains("--run-case=K-1") && arguments.contains("--start-step=3") && arguments.contains("--bundle-id=com.apple.mobilesafari"))
        #expect(!arguments.contains { $0.hasPrefix("--end-step") })
        // The runner announces the case again; steps 1 and 2 come back with their results, 3 and 4 start fresh.
        run.consume(event(["t": "case", "title": "T", "startStep": 3, "steps": steps]))
        #expect(run.steps.map(\.status) == [.passed, .passed, .running, .pending] || run.steps.map(\.status) == [.passed, .passed, .pending, .pending])
        #expect(run.steps[0].actions.count == 1 && run.steps[2].actions.isEmpty)
        #expect(run.failedStep == nil, "the new run has not failed yet")
    }

    @Test("Retry runs exactly one step and keeps every other result")
    func retry() async throws {
        let recorder = Recorder()
        let run = stoppedRun(recorder)
        try await Task.sleep(nanoseconds: 200_000_000)
        run.retry(step: 2)
        let arguments = try #require(recorder.arguments.last)
        #expect(arguments.contains("--start-step=2") && arguments.contains("--end-step=2"))
        run.consume(event(["t": "case", "title": "T", "startStep": 2, "steps": steps]))
        #expect(run.steps[0].status == .passed && run.steps[2].status == .failed && run.steps[1].actions.isEmpty)
    }

    @Test("Run failed steps skips the steps that passed after the first failure")
    func failedOnly() async throws {
        let recorder = Recorder()
        let run = CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: recorder)
        run.start(key: "k-1")
        run.consume(event(["t": "case", "title": "T", "steps": steps]))
        for (number, status) in [(1, "failed"), (2, "passed"), (3, "failed"), (4, "passed")] {
            run.consume(event(["t": "row", "id": "\(number).a", "number": number, "intent": "i", "action": "tap", "status": status, "detail": "d"]))
        }
        run.consume(event(["t": "done", "outcome": "FAILED", "failedStep": 1]))
        run.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        run.runFailedSteps()
        let arguments = try #require(recorder.arguments.last)
        #expect(arguments.contains("--skip-steps=2,4") && !arguments.contains { $0.hasPrefix("--start-step") }, "starting at step 1 needs no start flag")
    }

    @Test("Nothing happens while a run is going or when there is nothing to continue")
    func guards() {
        let recorder = Recorder()
        let fresh = CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: recorder)
        fresh.resume(); fresh.retry(step: 1); fresh.runFailedSteps()
        #expect(recorder.arguments.isEmpty)
    }
}

@MainActor
@Suite("Live run: current step, activity and reasoning")
struct CaseRunLiveTests {
    private func event(_ fields: [String: Any]) -> String {
        "@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    private let steps: [[String: Any]] = (1...4).map { ["number": $0, "text": "Step \($0)"] }

    /// A run in progress: four steps, started.
    private func liveRun() -> CaseRunState {
        let run = CaseRunState(projectRoot: ProductFixtures.tempDir(), launcher: FakeLauncher(run: FakeRun()))
        run.start(key: "k-1")
        run.consume(event(["t": "case", "title": "T", "steps": steps]))
        return run
    }

    private func row(_ run: CaseRunState, _ number: Int, _ status: String, id: String? = nil) {
        run.consume(event(["t": "row", "id": id ?? "\(number).a", "number": number, "intent": "do \(number)", "action": "tap", "status": status, "detail": "d"]))
    }

    @Test("The step the runner reports is the running one, and the rest follow from the rows")
    func currentStep() {
        let run = liveRun()
        run.consume(event(["t": "step", "number": 1, "state": "started"]))
        #expect(run.currentStep == 1 && run.steps.map(\.status) == [.running, .pending, .pending, .pending] && run.steps[0].isCurrent)
        row(run, 1, "passed")
        run.consume(event(["t": "step", "number": 1, "state": "finished"]))
        run.consume(event(["t": "step", "number": 2, "state": "started"]))
        #expect(run.currentStep == 2 && run.steps.map(\.status) == [.passed, .running, .pending, .pending])
    }

    @Test("A step being retried is running, not failed, and the step after it does not look like the one in progress")
    func retryIsNotAFailure() {
        let run = liveRun()
        run.consume(event(["t": "step", "number": 1, "state": "started"]))
        row(run, 1, "failed")
        // Before the runner says it is retrying, the failed step still reads as running (it is the current step).
        #expect(run.steps[0].status == .running)
        run.consume(event(["t": "step", "number": 1, "state": "retrying", "attempt": 2]))
        #expect(run.currentAttempt == 2 && run.steps[0].status == .running && run.steps[0].attempt == 2)
        #expect(run.steps[1].status == .pending, "step 2 is not the one being worked on")
        row(run, 1, "passed", id: "1.b")
        run.consume(event(["t": "step", "number": 1, "state": "finished"]))
        #expect(run.currentStep == nil)
    }

    @Test("Activity is what the runner is doing now, and is cleared when the step changes")
    func activity() {
        let run = liveRun()
        run.consume(event(["t": "step", "number": 1, "state": "started"]))
        run.consume(event(["t": "activity", "step": 1, "kind": "plan", "text": "Asking the fast model what to do next"]))
        #expect(run.currentActivity?.text == "Asking the fast model what to do next" && run.currentActivity?.kind == "plan" && run.currentActivity?.step == 1)
        run.consume(event(["t": "step", "number": 1, "state": "finished"]))
        #expect(run.currentActivity == nil)
    }

    @Test("The selection follows the current step until the person picks another, and Follow live returns to it")
    func followLive() {
        let run = liveRun()
        run.consume(event(["t": "step", "number": 1, "state": "started"]))
        #expect(run.selectedStep == 1 && run.followLive)
        run.select(3)
        run.consume(event(["t": "step", "number": 1, "state": "finished"]))
        run.consume(event(["t": "step", "number": 2, "state": "started"]))
        #expect(run.selectedStep == 3 && !run.followLive, "the person's choice stays")
        run.followCurrentStep()
        #expect(run.selectedStep == 2 && run.followLive)
        run.consume(event(["t": "step", "number": 2, "state": "finished"]))
        run.consume(event(["t": "step", "number": 3, "state": "started"]))
        #expect(run.selectedStep == 3, "following again")
        run.select(3)
        #expect(run.followLive, "selecting the current step keeps following")
    }

    @Test("A step's timeline puts reasoning and actions in the order they arrived; an update keeps its place")
    func timeline() {
        let run = liveRun()
        run.consume(event(["t": "step", "number": 1, "state": "started"]))
        run.consume(event(["t": "think", "step": 1, "phase": "observe", "text": "Read the screen: 12 elements."]))
        run.consume(event(["t": "think", "step": 1, "phase": "plan", "text": "Plan: tap Save"]))
        row(run, 1, "running")
        run.consume(event(["t": "think", "step": 1, "phase": "judge", "text": "Looks right"]))
        row(run, 1, "passed")      // the same action finishing
        run.consume(event(["t": "think", "step": 2, "phase": "plan", "text": "another step"]))
        let kinds = run.timeline(for: 1).map { item -> String in
            switch item { case .thought(let t): "thought:\(t.kind)"; case .action(let a): "action:\(a.status.rawValue)" }
        }
        #expect(kinds == ["thought:observe", "thought:plan", "action:passed", "thought:judge"])
        #expect(run.timeline(for: 2).count == 1)
    }

    @Test("A question carries the step it was asked on")
    func promptStep() {
        let run = liveRun()
        run.consume(event(["t": "step", "number": 3, "state": "started"]))
        run.consume(event(["t": "prompt", "id": "p", "kind": "approval", "title": "Approve", "message": "Delete the item\nTarget: Trash", "secure": false]))
        #expect(run.prompt?.step == 3)
    }

    @Test("A wait for the person to log in shows with its timeout, takes no input, and clears when it ends")
    func waitingForLogin() {
        let run = liveRun()
        run.consume(event(["t": "waiting", "id": "login", "kind": "wait-login", "title": "Waiting for you to log in", "message": "Log in on the simulator", "timeout": 600]))
        #expect(run.prompt?.isWaitOnly == true && run.prompt?.timeout == 600)
        run.consume(event(["t": "waiting-done", "id": "login", "result": "done"]))
        #expect(run.prompt == nil)
    }

    @Test("A runner that sends no step events still shows the first unfinished step as running")
    func olderRunner() {
        let run = liveRun()
        row(run, 1, "passed")
        #expect(run.steps.map(\.status) == [.passed, .running, .pending, .pending])
    }
}
