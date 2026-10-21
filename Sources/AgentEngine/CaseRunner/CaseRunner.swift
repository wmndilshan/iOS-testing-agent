import Foundation
import AgentCore
import AgentInfrastructure
import TestCaseSources

/// The flags of `--run-case=<KEY>`.
struct CaseRunFlags {
    let args: [String]

    func value(_ name: String) -> String? { args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) } }
    func has(_ flag: String) -> Bool { args.contains("--\(flag)") }
    /// Every value of a flag given more than once: `--use=Test1=Test2 --use=a=b`.
    func values(_ name: String) -> [String] { args.filter { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) } }
    func int(_ name: String) -> Int? { value(name).flatMap { Int($0) } }

    var startStep: Int { int("start-step") ?? 1 }
    var endStep: Int { int("end-step") ?? Int.max }
    /// `--skip-steps=8,12` leaves those steps out (reported as skipped), for a step the operator knows cannot run yet.
    var skippedSteps: Set<Int> { Set((value("skip-steps") ?? "").split(separator: ",").compactMap { Int($0) }) }
    var maxConsecutiveFailures: Int { int("max-consecutive-failures") ?? 1 }
    /// How many times a failed step is run again before the run stops (`--retries=0` turns it off).
    var retries: Int { max(0, int("retries") ?? 1) }
    var judgeEnabled: Bool { value("judge") != "off" }
    var skillsEnabled: Bool { value("skills") != "off" }
}

// `--run-case=<KEY> --mode=LIVE_AUTONOMOUS_AFTER_LOGIN|NON_LIVE_TEST [--start-step=N] [--end-step=N] [--skip-steps=8,12]
//                  [--ir=<TestIR.json>] [--provider=deepseek|gemini] [--model=<name>] [--bundle-id=<id>] [--username=<name>]
//                  [--skills=off] [--judge=off] [--judge-models=a,b] [--allow-destructive] [--refresh] [--events]
//                  [--max-consecutive-failures=N] [--retries=N] [--repo=<dir>] [--cases-dir=<dir>]`
//
// Default (grounded) flow, per case step: observe the live accessibility tree -> derive the real UI vocabulary -> generate that
// step's TestIR against it (regenerated with grounding feedback if a target is not on screen) -> TestIRValidator -> proposal ->
// approval -> ScenarioExecutionController.dispatchCurrentStep -> deterministic verification -> screenshot judge. With `--ir` a
// complete, pre-generated document is run instead. Every dispatch goes through the trusted spine either way.
//
// A test case is a sequence: a failed step leaves the app in a state the later steps do not expect, so the default is to stop
// at the first failure and mark the rest not executed. `--max-consecutive-failures=N` allows N failures in a row. A failed step is first retried once (`--retries=0` turns that off) after the app is checked to be in front and logged in; `--start-step=N` continues a stopped run from step N.
//
// In LIVE_AUTONOMOUS_AFTER_LOGIN the approval is the CLI policy's `explicitAutomationPolicy`, printed and recorded per step. The
// password step (the step carrying `[CREDENTIALS]`) and the login that follows are performed by the human and never dispatched
// by the agent. Progress is written to `.runs/cases/<KEY>-<timestamp>.json` after every step.

@MainActor
extension Engine {
    static func runCase(key: String, args: [String]) async {
        let flags = CaseRunFlags(args: args)
        print("================================================================")
        print("    Test Case Runner — \(key)")
        print("================================================================")
        guard let mode = CLIExecutionMode.parse(from: args), mode == .liveAutonomousAfterLogin || mode == .nonLiveTest else {
            print("✗ --run-case requires --mode=LIVE_AUTONOMOUS_AFTER_LOGIN or --mode=NON_LIVE_TEST.")
            await terminate(1)
        }
        print("Execution Mode: \(mode.rawValue)")
        if mode == .liveAutonomousAfterLogin {
            print("AUTONOMOUS MODE: every step after the password step is approved by scripted CLI policy, not a human.")
            print("Each approval is disclosed below and recorded in the report. This is not HITL evidence.")
        }

        let projectRoot = WorkingDirectory.url
        let root = InfrastructureFactory(projectRoot: projectRoot)
        activity(step: 0, kind: "wait", "Checking that no other run is in progress")
        await acquireRunLock(runsDirectory: root.runsDirectory)
        activity(step: 0, kind: "plan", "Loading the test case")
        var definition = CaseDefinition(await loadCase(key: key, args: args, projectRoot: projectRoot, handWrittenDirectory: flags.value("cases-dir")))
        emitsEvents = flags.has("events")
        if let username = flags.value("username") { definition = definition.withUsername(username) }
        print("Case: \(definition.title) (\(definition.steps.count) steps)")
        emit(["t": "case", "key": definition.key, "title": definition.title, "startStep": flags.startStep, "steps": definition.steps.map { ["number": $0.number, "text": $0.text] }])

        // The human performs the case step that carries the credential placeholder and the login that follows it.
        let humanNumbers: Set<Int> = emitsEvents ? [] : (definition.steps.last { $0.text.contains("[CREDENTIALS]") }.map { [$0.number, $0.number + 1] } ?? [])

        activity(step: 0, kind: "observe", "Finding the simulator")
        let resolution = await SimulatorTargetResolver.resolve(preferred: SimulatorTargetConfiguration.current, manager: SimctlSimulatorClient())
        print(resolution.note)
        let simulatorUDID = resolution.target.udid
        // The app under test: Safari by default, or any installed app with --bundle-id.
        let bundleID = flags.value("bundle-id") ?? SimulatorTargetConfiguration.current.bundleID
        let logger = root.makeLogger()
        let placeholderStep = ScenarioStep(id: "placeholder", name: "placeholder", description: "placeholder", toolName: "tap_element", locator: ScenarioLocator(role: "button"))
        let placeholder = SafeScenario(id: key, name: definition.title, purpose: "Case runner bookkeeping; the step checked at every stage is the compiled IR step.",
                                       initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: placeholderStep)
        let catalog = ScenarioCatalog(scenarios: [placeholder])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog), clock: SystemClock(),
                                                     scenarioTimeoutSeconds: mode.isLive ? 900.0 : 120.0)
        controller.logger = logger
        guard let driver = root.makeIDBDriver(simulatorUDID: simulatorUDID, isLiveExecutionEnabled: mode.isLive) else {
            print("✗ idb is not installed. Install idb-companion and fb-idb (see README), then run again.")
            await terminate(1)
        }
        print("Driver: idb")
        let registry = ToolRegistry(projectRoot: projectRoot, simulatorDestinationID: simulatorUDID, driver: driver,
                                    artifactStore: root.makeArtifactStore(), logger: logger)
        controller.executionMode = mode.isLive ? .live : .simulation
        controller.configureRunContext(appIdentity: AppIdentity(bundleID: bundleID, displayName: bundleID), simulatorID: simulatorUDID,
                                       simulatorName: resolution.target.name, executionMode: mode.rawValue)
        runContext = CLIRunContext(controller: controller, history: RunHistoryStore(directory: root.runsDirectory), mode: mode)

        let reportURL = root.caseRunsDirectory.appendingPathComponent("\(key)-\(Int(Date().timeIntervalSince1970)).json")
        let session = CaseRunSession(key: key, title: definition.title, mode: mode, controller: controller, driver: driver, registry: registry, bundleID: bundleID,
                                     reportURL: reportURL, maxConsecutiveFailures: flags.maxConsecutiveFailures, allowDestructive: flags.has("allow-destructive"))

        if let irPath = flags.value("ir") {
            guard let data = FileManager.default.contents(atPath: irPath), let ir = TestIR.decode(data) else {
                print("✗ \(irPath) is not a TestIR document.")
                await terminate(1)
            }
            print("TestIR loaded from \(irPath): whole-document mode (labels are not grounded against the live screen).")
            session.begin()
            await session.runDocument(ir: ir, rowPrefix: "", stepNumber: nil, startStep: flags.startStep, humanNumbers: humanNumbers)
        } else {
            await runGrounded(definition, flags: flags, root: root, session: session, humanNumbers: humanNumbers)
        }
        await session.finish()
    }

    /// Two runs share one simulator; overlapping them makes both hang.
    private static func acquireRunLock(runsDirectory: URL) async {
        let lockURL = runsDirectory.appendingPathComponent("cases/active-run.lock")
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text = try? String(contentsOf: lockURL, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != getpid(), kill(pid, 0) == 0 {
            print("✗ Another case run (process \(pid)) is already using the simulator. Stop it first (Ctrl+C in its terminal), then start again.")
            await terminate(1)
        }
        try? String(getpid()).write(to: lockURL, atomically: true, encoding: .utf8)
    }

    /// The default flow: every step is planned against the live screen, run, judged and (when verified) learned.
    private static func runGrounded(_ original: CaseDefinition, flags: CaseRunFlags, root: InfrastructureFactory, session: CaseRunSession, humanNumbers: Set<Int>) async {
        guard let llm = makeLLMClient(provider: flags.value("provider") ?? "deepseek", model: flags.value("model") ?? "deepseek-chat") else { await terminate(1) }
        // The cheap calls (is the step done? plan the result checks) use the fast model; action planning keeps the chosen one.
        let provider = flags.value("provider") ?? "deepseek"
        let fastLLM = (provider == "deepseek" ? makeLLMClient(provider: provider, model: "deepseek-chat") : nil) ?? llm
        // The screenshot judge decides whether a step's expected result is really on screen. A text check on the accessibility
        // tree cannot see selection or covering drawers, so a step passes only when the judge agrees as well.
        var judge: JudgePool? = nil
        if flags.judgeEnabled {
            guard let pool = JudgePool.configured(modelsFlag: flags.value("judge-models")) else {
                print("✗ The screenshot judge needs the Gemini configuration (GEMINI_API_KEY). Pass --judge=off to run without it.")
                await terminate(1)
            }
            judge = pool
        }
        activity(step: 0, kind: "plan", "Getting ready: the screenshot judge and the learned steps")
        let skills: StepSkillStore? = flags.skillsEnabled ? root.makeStepSkillStore() : nil
        print("Grounded mode: each step is generated against the live screen. Learned skills: \(skills == nil ? "off" : "replayed when the start screen matches, learned from verified steps").\n")
        // Test data the case leaves open (`[HELD_SYMBOL]`) is asked for before the run, like the username: a placeholder nobody fills in sends the
        // planner looking for something that does not exist, and it may change the app trying to find it.
        var definition = original
        if emitsEvents {
            for name in definition.placeholders {
                let message = "The case uses the test data placeholder [\(name)] (for example a symbol the account holds). Enter the value to use, or skip to run with the placeholder as written."
                guard let value = ask(id: "data-\(name)", kind: "input", title: name, message: message, secure: false)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
                definition = definition.withValues([name: value])
            }
        }
        // With --repo, a step that cannot find its way reads the app's source (read-only) and plans again with what it shows.
        var codeGuide: CodeGuide? = nil
        if let repo = flags.value("repo"), !repo.isEmpty {
            let url = URL(fileURLWithPath: (repo as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                codeGuide = CodeGuide(root: url, projectRoot: WorkingDirectory.url)
                codeGuide?.prewarm()
                print("Source: \(url.path) (read when a step cannot find its way)")
            }
        }
        // What the person said about this case before (kept until cleared) and on the command line: "use Test2 instead of Test1".
        let guidanceStore = GuidanceStore(directory: root.runsDirectory.appendingPathComponent("guidance"))
        if flags.has("clear-guidance") { guidanceStore.clear(definition.key) }
        var guidance = guidanceStore.load(definition.key)
        for use in flags.values("use") { guidance.merge(GuidanceParser.parse(use.replacingOccurrences(of: "=", with: " → "))) }
        for note in flags.values("note") { guidance.merge(GuidanceParser.parse(note)) }
        guidanceStore.save(guidance, for: definition.key)
        session.setGuidance(guidance)
        if emitsEvents || isatty(STDIN_FILENO) != 0 { StdinAnswers.shared.start() }
        if !guidance.isEmpty {
            print("Guidance in use: \(guidance.summary)")
            emit(["t": "guidance", "text": guidance.summary, "substitutions": guidance.substitutions.map { ["from": $0.from, "to": $0.to] }, "notes": guidance.notes])
        }
        let base = definition
        definition = base.applying(guidance)
        session.begin()
        session.describe(steps: definition.steps, startStep: flags.startStep, endStep: flags.endStep)
        // One step through the normal planner, judge and skills: also what a retry and a re-login run.
        // The first action of the next step is planned while this step is judged (`--prefetch=off` to turn it off).
        let prefetch: PlanPrefetch? = flags.value("prefetch") == "off" || judge == nil ? nil : PlanPrefetch()
        func runStep(_ step: CaseStep, next: CaseStep? = nil, attemptCap: Int? = nil) async {
            var planner = StepPlanner(session: session, strongLLM: llm, fastLLM: fastLLM, step: step, startStep: flags.startStep)
            planner.prefetch = prefetch
            var runner = StepRunner(session: session, planner: planner, llm: fastLLM, judge: judge, skills: skills, step: step, codeGuide: codeGuide, plannedChecks: flags.value("verify") == "tree")
            runner.prefetch = prefetch
            runner.attemptCap = attemptCap
            if let prefetch, let next, PlanPrefetch.isEligible(next.text), !flags.skippedSteps.contains(next.number), next.number <= flags.endStep {
                runner.beforeJudging = {
                    guard session.blockedReason == nil, !session.aborted else { return }
                    var current = session.recentObservation(maxAge: 2)
                    if current == nil { current = await session.observe() }
                    guard let screen = current else { return }
                    // A step that a learned skill will replay needs no plan.
                    if let skills, await skills.applicable(testKey: session.key, stepText: next.text, bundleID: session.bundleID, observation: screen) != nil { return }
                    let upcoming = StepText(next.text)
                    let nextPlanner = StepPlanner(session: session, strongLLM: llm, fastLLM: fastLLM, step: next, startStep: flags.startStep)
                    let note = PlannerNotes.actionNote(stepText: next.text, done: [], judgeFeedback: nil, codeFacts: nil)
                    prefetch.start(step: next.number, observation: screen) { observation in
                        await nextPlanner.planAhead(upcoming.action, note: note, observation: observation)
                    }
                }
            }
            await runner.run()
        }
        let recovery = StepRecovery(session: session, loginSteps: StepRecoveryPolicy.loginSteps(in: definition.steps), runStep: { await runStep($0) })
        activity(step: 0, kind: "act", "Bringing \(session.bundleID) to the front")
        await session.ensureAppInFront()
        // A run that resumes in the middle of a case first makes sure the app is in front and logged in.
        if flags.startStep > 1, let first = definition.steps.first(where: { $0.number >= flags.startStep && $0.number <= flags.endStep }) {
            Engine.emit(["t": "think", "step": first.number, "phase": "recovery", "text": "Resuming at step \(first.number)."])
            await recovery.prepare(for: first)
        }
        // What the person says to the running case is heard before each step: it changes this step and the ones after it.
        func hearGuidance(for step: inout CaseStep) {
            let said = takeGuidance()
            if !said.isEmpty {
                guidance.merge(said)
                guidanceStore.save(guidance, for: base.key)
                session.setGuidance(guidance)
                definition = base.applying(guidance)
                print("  Guidance from you: \(said.summary). Applied from step \(step.number).")
                emit(["t": "guidance", "text": guidance.summary, "substitutions": guidance.substitutions.map { ["from": $0.from, "to": $0.to] }, "notes": guidance.notes, "heard": said.summary])
                Engine.reasoning(step: step.number, kind: "decide", "You told the agent: \(said.summary).")
            }
            if let fresh = definition.steps.first(where: { $0.number == step.number }) { step = fresh }
        }
        for var step in definition.steps where step.number >= flags.startStep && step.number <= flags.endStep {
            if session.aborted { break }
            hearGuidance(for: &step)
            // The app is told which step this is before anything about it happens, so a question asked now is shown against the right step.
            Engine.stepState(step.number, "started")
            // With --events the app is listening: the username is asked for when its step comes, not before the run starts.
            if emitsEvents, flags.value("username") == nil, step.text.lowercased().contains("username"), !step.text.contains("[CREDENTIALS]") {
                guard let name = ask(id: "username", kind: "input", title: "Username", message: "Step \(step.number) enters the username. Which username should the test log in with?", secure: false), !name.isEmpty else {
                    session.recordRow("\(step.number).input", number: step.number, intent: step.text, action: "input", .failed, "no username was entered")
                    continue
                }
                step = definition.withUsername(name, onlyStep: step.number).steps.first { $0.number == step.number } ?? step
            }
            if flags.skippedSteps.contains(step.number) {
                session.recordRow("\(step.number).skip", number: step.number, intent: step.text, action: "skip", .skipped, "skipped by --skip-steps")
                continue
            }
            if emitsEvents, step.text.contains("[CREDENTIALS]") {
                guard let password = ask(id: "password", kind: "password", title: "Password", message: "Enter the password for step \(step.number). It is typed into the app and never stored.", secure: true), !password.isEmpty else {
                    session.recordRow("\(step.number).input", number: step.number, intent: step.text, action: "input", .failed, "no password was entered")
                    continue
                }
                session.setCredential("TEST_USER_PASSWORD", password)
            }
            if humanNumbers.contains(step.number) {
                let isPassword = step.text.contains("[CREDENTIALS]")
                if isPassword { await session.waitForHumanLogin() }
                session.recordRow("\(step.number).human", number: step.number, intent: step.text, action: "human",
                                  .humanCompleted, isPassword ? "password entered by the human" : "performed by the human as part of login")
                continue
            }
            print("--- step \(step.number): \(step.text)")
            // A step that tells a person to do what the runner cannot (a code, a captcha, an approval elsewhere, Face ID) is theirs to do: the run waits.
            if let action = HumanActionPolicy.stepNeedsPerson(step.text) {
                await session.waitForPerson(action)
                session.recordRow("\(step.number).human", number: step.number, intent: step.text, action: "human", session.aborted ? .failed : .humanCompleted,
                                  session.aborted ? "nobody did it in time" : "\(action.kind.rawValue) handled by the person")
                Engine.stepState(step.number, "finished")
                continue
            }
            // Phase A plans and runs the action against the screen as it is now. Phase B plans the expected result against the
            // screen the action produced: an element that only exists after the action cannot be grounded before it.
            session.clock.begin(step: step.number)
            await runStep(step, next: definition.steps.first { $0.number > step.number })
            // A step that failed gets one more try, once the app is in front and logged in. A failure on the retry stops the run as before.
            if session.stepFailed(step.number), session.blockedReason == nil, let message = StepRecoveryPolicy.loginRejection(await session.observe()) {
                // Retrying cannot fix wrong login details: stop here and say so, instead of a failure that reads like a UI problem.
                let reason = "The app rejected the login (\"\(message)\"). The username or password is wrong: correct them, then resume from step \(step.number)."
                print("  \(reason)")
                Engine.emit(["t": "think", "step": step.number, "phase": "recovery", "text": reason])
                session.block(reason)
            }
            // The app said a name from the test data is taken (Test1 already exists): suggest another, ask, and run the steps again with the new value.
            if session.stepFailed(step.number), session.blockedReason == nil, emitsEvents || isatty(STDIN_FILENO) != 0,
               let conflict = ConflictDetector.detect(await session.observe(), stepText: step.text) {
                switch await resolveConflict(conflict, at: step, base: base, guidance: &guidance, store: guidanceStore, session: session) {
                case .rerun(let from):
                    definition = base.applying(guidance)
                    session.beginRetry(step: step.number)
                    for number in from...step.number {
                        guard let again = definition.steps.first(where: { $0.number == number }) else { continue }
                        Engine.stepState(number, "retrying", attempt: 2)
                        await runStep(again, attemptCap: 1)
                        if !session.finishRetry(step: number) { break }
                    }
                    if !session.stepFailed(step.number) || session.aborted { session.clock.finish(); Engine.stepState(step.number, "finished"); continue }
                case .skip:
                    session.recordRow("\(step.number).skip", number: step.number, intent: step.text, action: "skip", .skipped, "skipped on your instruction after a name clash")
                    session.clock.finish(); Engine.stepState(step.number, "finished"); continue
                case .stop, .none: break
                }
            }
            if session.stepFailed(step.number), flags.retries > 0, session.blockedReason == nil, !humanNumbers.contains(step.number) {
                for attempt in 1...flags.retries {
                    print("  Step \(step.number) failed. Retrying (\(attempt) of \(flags.retries)) after checking the app.")
                    Engine.emit(["t": "think", "step": step.number, "phase": "recovery", "text": "Step failed; retrying (\(attempt) of \(flags.retries))."])
                    session.beginRetry(step: step.number)
                    Engine.stepState(step.number, "retrying", attempt: attempt + 1)
                    await recovery.prepare(for: step)
                    await runStep(step, attemptCap: 1)
                    if session.finishRetry(step: step.number) { print("  Step \(step.number) passed on its retry."); break }
                }
            }
            session.clock.finish()
            Engine.stepState(step.number, "finished")
        }
    }

    enum ConflictDecision { case rerun(from: Int), skip, stop, none }

    /// A value from the test data is taken. The agent suggests the next free name and asks; the person picks it, types another, or says something
    /// else in words. Nobody answering counts as taking the suggestion, and the report says so.
    private static func resolveConflict(_ conflict: DataConflict, at step: CaseStep, base: CaseDefinition, guidance: inout RunGuidance, store: GuidanceStore,
                                        session: CaseRunSession) async -> ConflictDecision {
        let onScreen = Set(await session.observe().map { $0.elements.flatMap { [$0.label, $0.value] }.compactMap { $0 } } ?? [])
        let suggestions = NameSuggester.suggest(for: conflict.value, avoiding: onScreen)
        guard let first = suggestions.first else { return .none }
        let skip = "Skip this step", stop = "Stop the run"
        let options = suggestions.map { "Use \($0) instead of \(conflict.value)" } + [skip, stop]
        let message = "The app says: “\(conflict.message)”. Step \(step.number) uses “\(conflict.value)”. Choose another value, or tell the agent what to do instead."
        let answer = askChoice(id: "conflict-\(step.number)", title: "“\(conflict.value)” already exists", message: message, options: options)
        var chosen: RunGuidance
        switch answer {
        case nil:
            print("  Nobody answered in time: using the suggestion \(first).")
            Engine.reasoning(step: step.number, kind: "decide", "Nobody answered; using \(first) instead of \(conflict.value).")
            chosen = RunGuidance(substitutions: [.init(from: conflict.value, to: first)])
        case skip?: return .skip
        case stop?: session.block("You chose to stop after “\(conflict.value)” was found to exist already."); return .stop
        case let text?:
            if let index = options.firstIndex(of: text), index < suggestions.count { chosen = RunGuidance(substitutions: [.init(from: conflict.value, to: suggestions[index])]) }
            else {
                chosen = GuidanceParser.parse(text)
                // A single word on its own is the value to use in place of the taken one.
                if chosen.substitutions.isEmpty, chosen.notes.count == 1, !text.contains(" "), text.count <= 40 { chosen = RunGuidance(substitutions: [.init(from: conflict.value, to: text)]) }
            }
        }
        guard !chosen.isEmpty else { return .none }
        // The value was typed where it first appears in the test data (as the steps read now), which can be steps before the one that failed.
        let applied = base.applying(guidance)
        let source = applied.steps.last { $0.number <= step.number && (StepText.testData(in: $0.text) ?? "").contains(conflict.value) }?.number ?? step.number
        guidance.merge(chosen)
        store.save(guidance, for: base.key)
        session.setGuidance(guidance)
        print("  Guidance: \(chosen.summary). Running the steps again.")
        emit(["t": "guidance", "text": guidance.summary, "substitutions": guidance.substitutions.map { ["from": $0.from, "to": $0.to] }, "notes": guidance.notes, "heard": chosen.summary])
        return .rerun(from: source)
    }

    /// Reads `DEEPSEEK_API_KEY`: real environment first, then a `.env` at the working directory.
    static func resolveDeepSeekAPIKey() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !Configuration.isPlaceholderKey(fromEnv) {
            return fromEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cwd = WorkingDirectory.url
        if let parsed = Configuration.parseEnvFile(at: cwd.appendingPathComponent(".env"))?["DEEPSEEK_API_KEY"], !Configuration.isPlaceholderKey(parsed) {
            return parsed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func makeLLMClient(provider: String, model: String) -> (any LLMClientProtocol)? {
        if provider == "gemini" {
            guard let config = try? Configuration.load() else { print("✗ Gemini configuration not found."); return nil }
            return LLMClient(config: config)
        }
        guard let apiKey = resolveDeepSeekAPIKey() else { print("✗ DEEPSEEK_API_KEY not found in environment or .env."); return nil }
        // deepseek-chat caps output at 8192 tokens, enough for one step; the reasoner's budget also covers its reasoning.
        return DeepSeekClient(apiKey: apiKey, model: model, maxTokens: model == "deepseek-chat" ? 8192 : 16000, requestTimeout: model == "deepseek-chat" ? 60 : 90)
    }
}
