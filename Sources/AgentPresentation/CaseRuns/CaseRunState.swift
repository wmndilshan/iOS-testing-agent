import Foundation
import SwiftUI
import AgentCore

/// Shows one test case run: its steps with results, what the planner decided, what the run is asking a person, and the outcome.
/// It only reads the run's event lines and writes answers back; it has no execution authority.
@MainActor
public final class CaseRunState: ObservableObject {
    public enum Status: String, Sendable {
        case pending, running, passed, failed, skipped, unsupported, human

        init(report: CaseRunReport.Status) {
            self = Self(rawValue: report == .humanCompleted ? "human" : report.rawValue) ?? .pending
        }

        public var tone: StatusTone {
            switch self {
            case .passed: .success
            case .failed: .failure
            case .running: .active
            case .unsupported: .warning
            case .pending, .skipped, .human: .neutral
            }
        }
    }

    public struct Action: Identifiable, Sendable, Equatable {
        public let id: String
        public let intent: String
        public var status: Status
        public var detail: String
        public var evidence: String
        /// Order of arrival among everything the run reported, so actions and reasoning can be shown in one timeline.
        public var sequence = 0
        public var at = Date()

        public init(id: String, intent: String, status: Status, detail: String, evidence: String) {
            self.id = id
            self.intent = intent
            self.status = status
            self.detail = detail
            self.evidence = evidence
        }
    }

    public struct Step: Identifiable, Sendable, Equatable {
        public let id: Int
        public let text: String

        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }

        public var actions: [Action] = []
        public var status: Status = .pending
        /// The runner is working on this step now (it said so), and which try it is on: a retried step is running, not failed.
        public var isCurrent = false
        public var attempt = 1
        /// Why the step failed: the detail of its first failed action.
        public var failureReason: String? { actions.first { $0.status == .failed }?.detail }
        public var evidence: String? { actions.reversed().first { !$0.evidence.isEmpty }?.evidence }
    }

    /// A line of the runner's reasoning. `kind`: observe, plan, act, judge, decide, check, code or recovery.
    public struct Thought: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let step: Int
        public let kind: String
        public let text: String
        public let date: Date
        public let sequence: Int
    }

    /// What the runner is doing at this moment, for the live line above the steps.
    public struct Activity: Sendable, Equatable {
        public let step: Int
        public let kind: String
        public let text: String
        public let since: Date
    }

    public enum TimelineItem: Identifiable, Sendable, Equatable {
        case thought(Thought)
        case action(Action)

        public var id: String {
            switch self {
            case .thought(let thought): "thought-\(thought.id)"
            case .action(let action): "action-\(action.id)"
            }
        }

        public var sequence: Int {
            switch self {
            case .thought(let thought): thought.sequence
            case .action(let action): action.sequence
            }
        }
    }

    public struct Prompt: Identifiable, Sendable, Equatable {
        public let id: String
        public let kind: String
        public let title: String
        public let message: String
        public let secure: Bool
        /// The step the run was on when it asked.
        public var step: Int? = nil
        /// Seconds the run waits before it stops, and when the wait began; both nil for a question with no limit.
        public var timeout: Int? = nil
        public var since = Date()
        /// A wait for something the person does outside the app (logging in on the simulator): there is nothing to type or approve.
        /// The choices of a question the agent has a suggestion for (the first one is the suggestion); empty for a question that is answered in words.
        public var options: [String] = []
        public var isWaitOnly: Bool { kind.hasPrefix("wait-") }
    }

    public enum Autonomy: String, CaseIterable, Identifiable, Sendable {
        case supervised = "Ask before critical actions"
        case full = "Fully autonomous"
        public var id: String { rawValue }
    }

    @Published public private(set) var caseKey = ""
    @Published public private(set) var title = ""
    @Published public private(set) var steps: [Step] = []
    @Published public private(set) var thoughts: [Thought] = []
    @Published public private(set) var log: [String] = []
    @Published public private(set) var prompt: Prompt?
    /// What the person told the agent to do differently, as the run reports it is using it ("Test1 → Test2; “keep the Table view”").
    @Published public private(set) var guidance = ""
    /// The instructions typed before a run ("use Test2 instead of Test1"); the run saves them for the case. `forgetSavedGuidance` clears what was saved.
    @Published public var instructions = ""
    @Published public var forgetSavedGuidance = false
    @Published public private(set) var isRunning = false
    @Published public private(set) var outcome: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var finishedAt: Date?
    @Published public var selectedStep: Int?
    /// The step the runner is working on now, from its own `step` events.
    @Published public private(set) var currentStep: Int?
    @Published public private(set) var currentAttempt = 1
    @Published public private(set) var currentActivity: Activity?
    /// The selection follows the current step until the person selects another one.
    @Published public private(set) var followLive = true
    /// The first step that failed in the run that just ended, when the runner said so.
    @Published public private(set) var failedStep: Int?
    /// Where the time went, by step, as the runner reports it.
    @Published public private(set) var timing = RunTiming()
    @Published public var autonomy: Autonomy = .supervised

    public let projectRoot: URL
    private let launcher: any CaseRunLaunching
    private var handle: (any CaseRunHandle)?
    /// The app the last run targeted, so a resume or retry needs no re-typing.
    public private(set) var lastBundleID: String?
    /// Results of steps this run keeps from an earlier one (a resume starts in the middle of a case); the `case` event brings them back.
    private var kept: [Int: Step] = [:]
    /// Whether the runner reports its steps. An older runner does not, and the current step is then the first one without results.
    private var hasStepEvents = false
    private var nextSequence = 0

    /// The local repository the agents read, asked for at the start of each run. When it names a folder, the runner may read it (never write)
    /// to see how the app's code builds and reaches a screen it cannot find.
    private let repositoryPath: @MainActor () -> String

    public init(projectRoot: URL, launcher: any CaseRunLaunching, repositoryPath: @escaping @MainActor () -> String = { "" }) {
        self.projectRoot = projectRoot
        self.launcher = launcher
        self.repositoryPath = repositoryPath
    }

    /// Keys of the cases available without a network: hand-written ones and ones fetched before.
    public func availableCaseKeys() -> [String] {
        // The Run view asks on every redraw, and every redraw while a run streams; the folders are listed at most every few seconds.
        if let known = knownCaseKeys, Date().timeIntervalSince(known.at) < 3 { return known.keys }
        let keys = listCaseKeys()
        knownCaseKeys = (keys, Date())
        return keys
    }

    private var knownCaseKeys: (keys: [String], at: Date)?

    private func listCaseKeys() -> [String] {
        var keys = Set<String>()
        for folder in ["TestCases", "Scripts/AIO/generated"] {
            let url = projectRoot.appendingPathComponent(folder)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
                if file.hasSuffix(".json"), !file.hasSuffix("_detail.json") { keys.insert(String(file.dropLast(5))) }
                if file.hasSuffix(".md") { keys.insert(String(file.dropLast(3))) }
            }
        }
        return keys.sorted()
    }

    /// Starts a case by its key. A key that is not available locally is fetched from its test case source by the runner.
    /// `startStep`/`endStep`/`skipSteps` run part of the case; `keeping` are results of earlier steps that stay on screen.
    public func start(key: String, bundleID: String? = nil, refresh: Bool = false, startStep: Int? = nil, endStep: Int? = nil,
                      skipSteps: [Int] = [], keeping: [Step] = []) {
        let key = key.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty, !isRunning else { return }
        reset(key: key)
        kept = Dictionary(keeping.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let bundleID, !bundleID.isEmpty { lastBundleID = bundleID }
        var arguments = ["--run-case=\(key)", "--mode=LIVE_AUTONOMOUS_AFTER_LOGIN", "--events", "--model=deepseek-reasoner"]
        if let startStep, startStep > 1 { arguments.append("--start-step=\(startStep)") }
        if let endStep { arguments.append("--end-step=\(endStep)") }
        if !skipSteps.isEmpty { arguments.append("--skip-steps=\(skipSteps.sorted().map(String.init).joined(separator: ","))") }
        if autonomy == .full { arguments.append("--allow-destructive") }
        if let bundleID, !bundleID.isEmpty { arguments.append("--bundle-id=\(bundleID)") }
        if refresh { arguments.append("--refresh") }
        if forgetSavedGuidance { arguments.append("--clear-guidance"); forgetSavedGuidance = false }
        arguments += Self.noteFlags(instructions)
        if case .ready = AgentChatState.status(ofRepositoryAt: repositoryPath()) { arguments.append("--repo=\(repositoryPath().trimmingCharacters(in: .whitespaces))") }
        do {
            let run = try launcher.launch(arguments: arguments)
            handle = run
            isRunning = true
            Task { [weak self] in
                for await line in run.lines { self?.consume(line) }
                self?.finished()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// What the person says to the agent while it runs ("use Test2 instead of Test1"): sent on the run's input, heard before the next step.
    public func tell(_ text: String) {
        let sentence = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard isRunning, !sentence.isEmpty else { return }
        handle?.send("@@NOTE \(sentence)")
        thoughts.append(Thought(step: currentStep ?? 0, kind: "decide", text: "You told the agent: \(sentence)", date: Date(), sequence: takeSequence()))
    }

    /// One `--note=` per sentence, on one line each, so what is typed cannot carry another flag or a line break into the command.
    static func noteFlags(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\n", with: ";").split(separator: ";").prefix(8)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { "--note=\($0.prefix(300))" }
    }

    // MARK: - Continuing a run that stopped

    /// A run that ended before the case did, and said which step stopped it: the person can pick it up from there.
    public var canResume: Bool { !isRunning && !caseKey.isEmpty && failedStep != nil && outcome != "PASSED" }

    /// Runs the case again from `step` to its end. Results of the steps before it stay as they were; the app is expected to be where the
    /// earlier step left it, and the runner checks it is in front and logged in before it starts.
    public func resume(fromStep step: Int? = nil) {
        guard let from = step ?? failedStep, !isRunning, !caseKey.isEmpty else { return }
        start(key: caseKey, bundleID: lastBundleID, startStep: from, keeping: steps.filter { $0.id < from })
    }

    /// Runs only `step` again, keeping every other step's result.
    public func retry(step: Int) {
        guard !isRunning, !caseKey.isEmpty else { return }
        start(key: caseKey, bundleID: lastBundleID, startStep: step, endStep: step, keeping: steps.filter { $0.id != step })
    }

    /// Runs only the steps that failed, keeping the rest. A step that depends on one skipped in between may still fail.
    public func runFailedSteps() {
        let failed = steps.filter { $0.status == .failed }.map(\.id)
        guard !isRunning, !caseKey.isEmpty, let first = failed.min() else { return }
        start(key: caseKey, bundleID: lastBundleID, startStep: first, skipSteps: steps.map(\.id).filter { !failed.contains($0) && $0 >= first },
              keeping: steps.filter { !failed.contains($0.id) })
    }

    public func stop() {
        handle?.terminate()
    }

    /// Answers the open prompt. For an approval the answer is "approve" or "deny".
    public func answer(_ text: String) {
        guard prompt != nil else { return }
        handle?.send(text)
        prompt = nil
    }

    // MARK: - Reading the run

    private func reset(key: String) {
        caseKey = key
        title = ""
        steps = []
        thoughts = []
        log = []
        prompt = nil
        guidance = ""
        outcome = nil
        errorMessage = nil
        selectedStep = nil
        failedStep = nil
        timing = RunTiming()
        kept = [:]
        currentStep = nil
        currentAttempt = 1
        currentActivity = nil
        followLive = true
        hasStepEvents = false
        nextSequence = 0
        startedAt = Date()
        finishedAt = nil
    }

    private func finished() {
        isRunning = false
        finishedAt = Date()
        handle = nil
        prompt = nil
        if outcome == nil { outcome = "STOPPED" }
        // A run that ended before it showed a single step failed to start: say why, from the runner's last line, instead of an empty screen.
        if steps.isEmpty, errorMessage == nil {
            let lines = log.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let reason = lines.last { $0.hasPrefix("✗") } ?? lines.last
            errorMessage = reason.map { $0.replacingOccurrences(of: "✗ ", with: "") } ?? "The test runner ended before the case started."
        }
        currentStep = nil
        currentActivity = nil
        refreshStatuses()
        // A run that ended on a failure shows the step that failed, unless the person is looking at another one.
        if followLive, let failed = steps.first(where: { $0.status == .failed })?.id { selectedStep = failed }
    }

    func consume(_ line: String) {
        guard line.hasPrefix("@@EVENT "), let data = line.dropFirst(8).data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let kind = event["t"] as? String else {
            if !line.isEmpty { log.append(line); if log.count > 2000 { log.removeFirst(500) } }
            return
        }
        switch kind {
        case "case":
            title = event["title"] as? String ?? ""
            steps = (event["steps"] as? [[String: Any]] ?? []).compactMap { raw in
                guard let number = raw["number"] as? Int, let text = raw["text"] as? String else { return nil }
                return kept[number] ?? Step(id: number, text: text)
            }
        case "row":
            guard let number = event["number"] as? Int, let index = steps.firstIndex(where: { $0.id == number }) else { return }
            var action = Action(id: event["id"] as? String ?? UUID().uuidString, intent: event["intent"] as? String ?? "",
                                status: Status(rawValue: Self.map(event["status"] as? String ?? "")) ?? .pending,
                                detail: event["detail"] as? String ?? "", evidence: event["evidence"] as? String ?? "")
            if let existing = steps[index].actions.firstIndex(where: { $0.id == action.id }) {
                // An update keeps its place in the timeline and its first time.
                action.sequence = steps[index].actions[existing].sequence
                action.at = steps[index].actions[existing].at
                steps[index].actions[existing] = action
            } else {
                action.sequence = takeSequence()
                steps[index].actions.append(action)
            }
            refreshStatuses()
        case "think":
            thoughts.append(Thought(step: event["step"] as? Int ?? 0, kind: event["phase"] as? String ?? "", text: event["text"] as? String ?? "", date: Date(), sequence: takeSequence()))
            // A very long run keeps its latest notes: the list is rebuilt on every redraw, so it cannot grow without end.
            if thoughts.count > 6000 { thoughts.removeFirst(1500) }
        case "step":
            guard let number = event["number"] as? Int else { return }
            hasStepEvents = true
            switch event["state"] as? String ?? "" {
            case "started": currentStep = number; currentAttempt = 1; currentActivity = nil
            case "retrying": currentStep = number; currentAttempt = event["attempt"] as? Int ?? currentAttempt + 1; currentActivity = nil
            default: if currentStep == number { currentStep = nil; currentActivity = nil }
            }
            refreshStatuses()
        case "activity":
            currentActivity = Activity(step: event["step"] as? Int ?? currentStep ?? 0, kind: event["kind"] as? String ?? "", text: event["text"] as? String ?? "", since: Date())
        case "prompt":
            prompt = Prompt(id: event["id"] as? String ?? "", kind: event["kind"] as? String ?? "input", title: event["title"] as? String ?? "",
                            message: event["message"] as? String ?? "", secure: event["secure"] as? Bool ?? false, step: currentStep,
                            timeout: event["timeout"] as? Int, options: event["options"] as? [String] ?? [])
        case "guidance":
            guidance = event["text"] as? String ?? ""
            if let heard = event["heard"] as? String, !heard.isEmpty {
                thoughts.append(Thought(step: currentStep ?? 0, kind: "decide", text: "Guidance: \(heard)", date: Date(), sequence: takeSequence()))
            }
        case "waiting":
            prompt = Prompt(id: event["id"] as? String ?? "waiting", kind: event["kind"] as? String ?? "waiting", title: event["title"] as? String ?? "Waiting for you",
                            message: event["message"] as? String ?? "", secure: false, step: currentStep, timeout: event["timeout"] as? Int)
        case "prompt-done", "waiting-done":
            prompt = nil
        case "timing":
            guard let step = event["step"] as? Int, let seconds = (event["seconds"] as? NSNumber)?.doubleValue else { return }
            let phases = (event["phases"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            timing.steps["\(step)"] = RunTiming.StepTime(seconds: seconds, phases: phases)
        case "done":
            outcome = event["outcome"] as? String
            if let failed = event["failedStep"] as? Int, failed > 0 { failedStep = failed }
        default:
            break
        }
    }

    /// How a step went, from how its actions went.
    nonisolated public static func aggregate(_ actions: [Status]) -> Status {
        if actions.contains(.failed) { return .failed }
        if actions.contains(.passed) { return .passed }
        if actions.contains(.unsupported) { return .unsupported }
        if actions.contains(.human) { return .human }
        if !actions.isEmpty, actions.allSatisfy({ $0 == .skipped }) { return .skipped }
        return .pending
    }

    private static func map(_ raw: String) -> String { raw == "humanCompleted" ? "human" : raw }

    private func takeSequence() -> Int {
        nextSequence += 1
        return nextSequence
    }

    private func refreshStatuses() {
        var firstOpen = true
        for index in steps.indices {
            var status = Self.aggregate(steps[index].actions.map(\.status))
            // The step the runner says it is on is running, even when an earlier try of it failed: a retry is not a failure.
            let current = isRunning && hasStepEvents && steps[index].id == currentStep
            steps[index].isCurrent = current
            steps[index].attempt = current ? currentAttempt : 1
            if current {
                status = .running
            } else if !hasStepEvents, status == .pending, firstOpen, isRunning {
                status = .running
            }
            steps[index].status = status
            if status == .pending || status == .running { firstOpen = false }
        }
        if let running = steps.first(where: { $0.status == .running })?.id, selectedStep == nil || (isRunning && followLive) { selectedStep = running }
    }

    // MARK: - Following the run

    /// The person selects a step. Selecting the one being worked on keeps following; selecting another stops the selection from jumping.
    public func select(_ step: Int?) {
        selectedStep = step
        followLive = step == nil || step == currentStep
    }

    /// Back to the step being worked on.
    public func followCurrentStep() {
        followLive = true
        if let current = currentStep ?? steps.first(where: { $0.status == .running })?.id { selectedStep = current }
    }

    /// What happened in a step, in the order it happened: the runner's reasoning and each action with its result.
    public func timeline(for step: Int) -> [TimelineItem] {
        let actions = steps.first { $0.id == step }?.actions ?? []
        let items = thoughts.filter { $0.step == step }.map(TimelineItem.thought) + actions.map(TimelineItem.action)
        return items.sorted { $0.sequence < $1.sequence }
    }
}
