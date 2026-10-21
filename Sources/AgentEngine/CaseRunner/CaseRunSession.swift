import Foundation
import AgentCore
import AgentInfrastructure

/// One run's controller, driver, report and failure accounting, shared by the grounded and whole-document flows. The behaviour
/// that is not bookkeeping lives in extensions: `DocumentRunner`, `ScreenJudge`, `SkillReplay`, `OffscreenReveal`, `HumanLogin`.
@MainActor
final class CaseRunSession {
    let key: String
    let title: String
    let mode: CLIExecutionMode
    let controller: ScenarioExecutionController
    let driver: any LiveExecutionControllable
    let registry: ToolRegistry
    let bundleID: String
    /// With this off (the default), an action that looks destructive always waits for a human approval at the terminal.
    let allowDestructive: Bool
    private let reportURL: URL
    private let maxConsecutiveFailures: Int
    private var report: CaseRunReport
    private let encoder = JSONEncoder()
    private var consecutiveFailures = 0
    private(set) var aborted = false
    /// Where each step's time goes.
    let clock = PhaseClock()
    private(set) var credentials = ProcessInfo.processInfo.environment
    /// Set when the run cannot continue for a reason unrelated to the app under test (for example no judge model has quota).
    private(set) var blockedReason: String?
    /// What the person told the run to do differently (saved per case); its notes reach the planner and the judge.
    private(set) var guidance = RunGuidance()
    func setGuidance(_ value: RunGuidance) { guidance = value }
    /// `role|identifier` and `role|label` of every element observed so far in this run. An absence assertion may only
    /// name an element that has really been seen, otherwise it would hold trivially for a misspelled name.
    private var seen: Set<String> = []
    var evidenceDirectory: URL { reportURL.deletingPathExtension() }

    init(key: String, title: String, mode: CLIExecutionMode, controller: ScenarioExecutionController, driver: any LiveExecutionControllable,
         registry: ToolRegistry, bundleID: String, reportURL: URL, maxConsecutiveFailures: Int, allowDestructive: Bool) {
        self.allowDestructive = allowDestructive
        self.key = key
        self.title = title
        self.mode = mode
        self.controller = controller
        self.driver = driver
        self.registry = registry
        self.bundleID = bundleID
        self.reportURL = reportURL
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.report = CaseRunReport(testKey: key, title: title, mode: mode.rawValue, steps: [])
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    func setCredential(_ name: String, _ value: String) { credentials[name] = value }
    func abort() { aborted = true }
    func block(_ reason: String) { blockedReason = reason; aborted = true }

    /// Records what a later run needs to continue this one: the app, the range run, and every planned step (with its text).
    func describe(steps: [CaseStep], startStep: Int, endStep: Int) {
        report.bundleID = bundleID
        report.startStep = startStep
        report.endStep = endStep == Int.max ? nil : endStep
        report.plannedSteps = steps.map { CaseRunReport.PlannedStep(number: $0.number, text: $0.text) }
        stepRange = startStep...endStep
        save()
    }

    private var stepRange: ClosedRange<Int> = 1...Int.max

    // MARK: - Retrying a step

    private var retryStartedAt = Date.distantFuture

    /// Lets a step that failed run again: the failure count and the abort it caused are cleared.
    func beginRetry(step number: Int) {
        consecutiveFailures = 0
        if blockedReason == nil { aborted = false }
        retryStartedAt = Date()
    }

    /// After a retry: true when it left no failure of its own (a row that failed again counts even if it reuses the first attempt's id). The
    /// first attempt's leftover failed rows are then marked as superseded, so the step reads as passed; otherwise the run stops, as it
    /// would have without a retry.
    func finishRetry(step number: Int) -> Bool {
        let failed = report.steps.filter { $0.sourceStepNumber == number && $0.status == .failed }
        let failedAgain = failed.contains { ($0.finishedAt ?? .distantPast) >= retryStartedAt }
        guard !failedAgain, !aborted else {
            aborted = true
            return false
        }
        for row in failed {
            report.update(row.id, status: .skipped, detail: "superseded: the step passed on its retry")
            Engine.emit(["t": "row", "id": row.id, "number": number, "intent": row.intent, "action": row.action, "status": "skipped",
                                         "detail": "superseded: the step passed on its retry", "evidence": row.evidencePath ?? "", "approval": ""])
        }
        save()
        return true
    }

    /// True when the step has a failed row.
    func stepFailed(_ number: Int) -> Bool {
        report.steps.contains { $0.sourceStepNumber == number && $0.status == .failed }
    }

    func begin() {
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        save()
        print("Report: \(reportURL.path)\n")
    }

    private func save() { try? encoder.encode(report).write(to: reportURL, options: .atomic) }

    // MARK: - Report rows

    /// Adds or updates one row of the report and prints it.
    func recordRow(_ id: String, number: Int, intent: String, action: String, _ status: CaseRunReport.Status, _ detail: String, approval: String? = nil) {
        if !report.steps.contains(where: { $0.id == id }) {
            report.steps.append(CaseRunReport.Step(id: id, sourceStepNumber: number, intent: intent, action: action))
        }
        report.update(id, status: status, detail: detail, approvalSource: approval)
        rowsSinceObserved += 1
        rowsSinceSettled += 1
        save()
        let mark = status == .passed ? "✓ PASS" : status == .failed ? "✗ FAIL" : status == .humanCompleted ? "☺ HUMAN" : "– \(status.rawValue.uppercased())"
        print("RESULT \(mark) \(id) (step \(number)): \(detail)")
        Engine.emit(["t": "row", "id": id, "number": number, "intent": intent, "action": action, "status": status.rawValue, "detail": detail,
                                     "evidence": report.steps.first { $0.id == id }?.evidencePath ?? "", "approval": approval ?? ""])
        switch status {
        case .passed: consecutiveFailures = 0
        case .failed:
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailures { aborted = true }
        default: break
        }
    }

    /// Lists the rows of a document before it runs, so the report shows every step as pending.
    func registerRows(_ rows: [(id: String, number: Int, intent: String, action: String)]) {
        for row in rows where !report.steps.contains(where: { $0.id == row.id }) {
            report.steps.append(CaseRunReport.Step(id: row.id, sourceStepNumber: row.number, intent: row.intent, action: row.action))
        }
        save()
    }

    func markRunning(_ id: String) {
        if let index = report.steps.firstIndex(where: { $0.id == id }) { report.steps[index].status = .running }
        save()
    }

    func attachEvidence(_ id: String, path: String) {
        report.attachEvidence(id, path: path)
        save()
    }

    // MARK: - Observation and evidence

    /// A fresh observation. It only reads the screen, so a transient failure is retried; a dispatch is never retried.
    func observe() async -> Observation? {
        for attempt in 1...3 {
            do {
                let observation = try await driver.captureObservation(bundleID: bundleID)
                controller.activeObservation = observation
                remember(observation)
                lastObserved = (observation, Date())
                return observation
            } catch DriverError.wrongApplication(_, let observed, let verdict) where verdict == .notForeground && attempt < 3 {
                // Another app slid in front (a system sheet, the home screen after a link): the app is brought back and the screen read again,
                // as a person would tap the app, rather than failing the step for something that is not the app's fault.
                if let launcher = driver as? any AppForegrounding {
                    print("  \(observed) is in front; bringing \(bundleID) back.")
                    await launcher.bringToForeground(bundleID: bundleID)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                print("  observation attempt \(attempt)/3 failed: \(SecretRedactor.redact(error.localizedDescription))")
                if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        return nil
    }

    /// The newest observation, when it is younger than `maxAge` seconds and nothing was dispatched since (a row is recorded after each dispatch).
    /// Saves reading the tree again right after it was read.
    private(set) var lastObserved: (observation: Observation, at: Date)?
    private var rowsSinceObserved = 0

    func recentObservation(maxAge: TimeInterval = 1.0) -> Observation? {
        guard let lastObserved, rowsSinceObserved == 0, Date().timeIntervalSince(lastObserved.at) <= maxAge else { return nil }
        return lastObserved.observation
    }

    private func remember(_ observation: Observation) {
        rowsSinceObserved = 0
        for element in observation.elements {
            if let identifier = element.identifier, !identifier.isEmpty { seen.insert("\(element.role)|\(identifier)") }
            if let label = element.label, !label.isEmpty { seen.insert("\(element.role)|\(label)") }
        }
    }

    /// A reason the step's "is absent" assertions would hold trivially, or nil when every one names an element that was seen.
    func vacuousAbsenceReason(_ step: IRStep) -> String? {
        var references: [(role: String?, identifier: String?, label: String?)] = []
        for element in step.verification?.forbiddenElements ?? [] { references.append((element.role, element.identifier, element.label)) }
        for case .elementDisappeared(let locator) in step.verification?.signals ?? [] { references.append((locator.role, locator.identifier, locator.label)) }
        for reference in references {
            guard let role = reference.role, let name = reference.identifier ?? reference.label else { return "an absence assertion names no element" }
            if !seen.contains("\(role)|\(name)") {
                return "absence assertion names \(role) '\(name)', which was never observed on any screen of this run; it would hold trivially"
            }
        }
        return nil
    }

    /// Screenshot of the screen as the step finished, kept with the run.
    func captureEvidence(rowID: String) async {
        guard let (path, _) = try? await driver.captureScreenshot(reason: rowID) else { return }
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let name = rowID.replacingOccurrences(of: "/", with: "-") + ".png"
        let destination = evidenceDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(atPath: path, toPath: destination.path)) != nil else { return }
        attachEvidence(rowID, path: "\(evidenceDirectory.lastPathComponent)/\(name)")
    }

    /// Waits until two observations 1.5 seconds apart show the same elements (or 10 seconds pass), so a result is checked
    /// against the screen the action produced rather than one that is still loading.
    func waitUntilScreenSettles() async {
        // Nothing was done since the screen last settled, and that was moments ago: there is nothing new to wait for.
        if rowsSinceSettled == 0, let lastSettled, Date().timeIntervalSince(lastSettled) < 3 { return }
        await clock.measure(.settle, "Waiting for the screen to settle") { await settleLoop() }
        lastSettled = Date()
        rowsSinceSettled = 0
    }

    private var lastSettled: Date?
    private var rowsSinceSettled = 0

    private static func signature(_ observation: Observation) -> [String] {
        observation.elements.map { "\($0.role)|\($0.identifier ?? "")|\($0.label ?? "")|\($0.frame.map { "\(Int($0.x)),\(Int($0.y))" } ?? "")" }
    }

    /// What the screen shows right now, as a comparable value (nil when it cannot be read).
    /// `allowRecent` reuses a read made moments ago with no action since (the one the settle loop just ended on), saving an idb process.
    func screenSignature(allowRecent: Bool = false) async -> [String]? {
        if allowRecent, let recent = recentObservation() { return Self.signature(recent) }
        guard let observation = try? await driver.captureObservation(bundleID: bundleID) else { return nil }
        lastObserved = (observation, Date())
        rowsSinceObserved = 0
        return Self.signature(observation)
    }

    private func settleLoop() async {
        // A read made moments ago with nothing done since is already the first of the two readings.
        var previous: [String]? = recentObservation(maxAge: 0.5).map(Self.signature)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard let observation = try? await driver.captureObservation(bundleID: bundleID) else { break }
            // Kept so the judge's tree note and the signature before judging need no further read.
            lastObserved = (observation, Date())
            rowsSinceObserved = 0
            let current = Self.signature(observation)
            if current == previous { return }
            previous = current
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Keeps the generated document so a decision (for example a branch arm) can be inspected afterwards.
    func saveGeneratedIR(_ ir: TestIR, number: Int, attempt: Int, phase: String) {
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try? ir.encoded().write(to: evidenceDirectory.appendingPathComponent("ir-step\(number)\(phase)-attempt\(attempt).json"))
    }

    // MARK: - Finish

    func finish() async {
        // A step that could not be executed at all is not a pass: the run is INCOMPLETE and exits non-zero.
        let outcome = report.count(.failed) > 0 ? "FAILED" : (blockedReason != nil ? "BLOCKED" : (report.count(.unsupported) > 0 ? "INCOMPLETE" : "PASSED"))
        let failedStep = report.firstFailedStep
        report.failedStep = failedStep
        report.timing = clock.timing
        let total = clock.timing.totalSeconds
        if total > 0 {
            let sums = clock.timing.totals.filter { $0.value >= 0.5 }.sorted { $0.value > $1.value }.map { "\($0.key) \(Int($0.value.rounded()))" }.joined(separator: ", ")
            print("\nTime: \(Int(total.rounded())) s in steps (\(sums))")
        }
        // Steps after the one that stopped the run still get a row, so the report (and the History view) lists every step of the case.
        if aborted { report.addUnreachedRows(in: stepRange, reason: failedStep.map { "not reached: the run stopped at step \($0)" } ?? "not reached: the run stopped") }
        report.closeOut(outcome: outcome)
        save()
        Engine.emit(["t": "done", "outcome": outcome, "passed": report.count(.passed), "failed": report.count(.failed), "skipped": report.count(.skipped),
                                     "failedStep": failedStep ?? 0, "resumable": failedStep != nil])
        if let blockedReason { print("\n⚠ BLOCKED: \(blockedReason). The steps that ran are reported; the rest were not executed.") }
        else if aborted { print("\n✗ Stopped after \(maxConsecutiveFailures) consecutive failure(s); the remaining steps were not executed.") }
        print("""

        ================================================================
        CASE RUN \(outcome): \(key)
          passed \(report.count(.passed))  failed \(report.count(.failed))  human \(report.count(.humanCompleted))  unsupported \(report.count(.unsupported))  skipped \(report.count(.skipped))
          report: \(reportURL.path)
        \(mode.isLive ? "LIVE simulator run; approvals were scripted by CLI policy (not human-in-the-loop evidence)." : "NON_LIVE_TEST: simulated driver, not live evidence.")
        ================================================================
        """)
        if let ctx = Engine.runContext { await Engine.persistRun(ctx, failed: outcome != "PASSED") }
        await Engine.terminate(outcome == "PASSED" ? 0 : 1)
    }
}
