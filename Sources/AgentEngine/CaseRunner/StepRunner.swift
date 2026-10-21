import Foundation
import AgentCore
import AgentInfrastructure

/// Runs one case step in the grounded flow: replay a learned skill, or plan and run actions screen by screen with the judge
/// looking after each round, then check the expected result and learn from a verified step.
@MainActor
struct StepRunner {
    let session: CaseRunSession
    let planner: StepPlanner
    let llm: any LLMClientProtocol
    let judge: JudgePool?
    let skills: StepSkillStore?
    let step: CaseStep
    /// The app's source, when a repository was given. Consulted once per step, when it cannot find its way.
    var codeGuide: CodeGuide? = nil
    /// After a judge pass, plan the tree check with a model (`--verify=tree`) instead of the instant label lookup.
    var plannedChecks = false
    /// Called once this step's actions are done and the screen has settled, just before the judge: the place to start planning the next step.
    var beforeJudging: (@MainActor () async -> Void)? = nil
    /// Dropped when the judge disagrees, since the next step will not start from this screen.
    var prefetch: PlanPrefetch? = nil
    /// The most tries at the step, when fewer than the usual three: a retry after a failed step gets one, since it exists to recover from a
    /// transient state (the app was away, the session ended), not to repeat the same corrective attempts that just failed.
    var attemptCap: Int? = nil

    func run() async {
        let text = StepText(step.text)
        // What the planner is told the step is: for a check-then-act step, only the action (the check is made separately, before it).
        let planningText = text.verifyThenAct == nil ? step.text : text.action + (text.expected.isEmpty ? "" : " Expected: " + text.expected)
        var done: [String] = []
        var executed: [IRStep] = []
        // A step learned before is repeated without planning or judging when the screen is the same as then. If the replay
        // does not end on the learned screen, the step is planned normally from wherever the replay left the app.
        let preObservation = await session.observe()
        if let skills, let pre = preObservation,
           let skill = await skills.applicable(testKey: session.key, stepText: step.text, bundleID: session.bundleID, observation: pre) {
            print("  replaying learned skill (\(skill.actions.count) action(s), used \(skill.successes) time(s)): no planning, no judge")
            Engine.reasoning(step: step.number, kind: "plan", "This screen matches a step learned before: replaying its \(skill.actions.count) action(s) with no planning and no judge.")
            if await session.clock.measure(.replay, "Replaying a learned step", { await session.replaySkill(skill, number: step.number) }) {
                await skills.recordSuccess(id: skill.id)
                return
            }
            await skills.recordFailure(id: skill.id)
            print("  the replay did not end on the learned screen; planning instead")
            done = skill.actions.map(\.intent)
        }
        // "Verify X, then tap Y": X is about the screen as it is now. Check it before acting; after the tap the screen has moved on.
        if let split = text.verifyThenAct, let judge, !session.aborted {
            await session.waitUntilScreenSettles()
            let before = await session.judgeExpectedResult(judge, number: step.number, stepText: split.check, expected: split.check, done: [], attempt: 1, isLastAttempt: true)
            Engine.emit(["t": "think", "step": step.number, "phase": "check", "text": before.passed ? "Checked before acting: \(split.check)." : "The check before acting did not hold: \(before.reason)"])
            if !before.passed { return }
        }
        // Test data the step names but no action has typed yet (checked against the actions run so far, each time a round is planned).
        var untypedData: String? { StepText.testData(in: step.text).flatMap { data in executed.contains { $0.action == .typeText } ? nil : data } }
        var feedback: String? = nil
        var judgePassed = false
        var codeFacts: String? = nil
        // Act, then let the judge look at the screen. When it says the expected result is not there, its reason goes back to
        // the planner for one more action, and the judge looks again; only the last attempt's verdict fails the step.
        // Corrective attempts act on a live app, so they are few: each extra one is another chance to do the wrong thing.
        let maxAttempts = min(attemptCap ?? 3, (judge == nil || text.verifiesOnly) ? 1 : 3)
        for attempt in 1...maxAttempts where !session.aborted {
            if !text.verifiesOnly {
                // A step can span several screens (open a drawer, open its settings, change them, save), and a screen that does
                // not exist yet cannot be planned. So plan what the current screen allows, run it, look again, and plan what
                // remains, until nothing is left.
                for round in 1...(attempt == 1 ? 8 : 1) where !session.aborted {
                    var note = PlannerNotes.actionNote(stepText: planningText, done: done, judgeFeedback: feedback, codeFacts: codeFacts, untypedData: untypedData)
                    func plan(_ note: String) async -> PlanRunResult {
                        await session.clock.measure(.plan, "Reading the screen and planning the next action") { await planner.planAndRun(text.action, phase: "a\(attempt)r\(round)", note: note, mentioning: text.action, actionsOnly: true,
                                                          // The first action of a step must work; later ones are best effort and the judge decides.
                                                          tentative: round > 1 || attempt > 1, previous: executed.last,
                                                          // The fast model plans the first try; the strong one is kept for a step that already failed (see `PlanningTier`).
                                                          tier: PlanningTier.choose(attempt: attempt), usePrefetch: attempt == 1 && round == 1) }
                    }
                    var result = await plan(note)
                    // The first action could not be found on this screen: read how the app's code builds and reaches it, and plan once more.
                    if !result.ok, round == 1, codeFacts == nil, let facts = await consultCode(failure: result.reason) {
                        codeFacts = facts
                        note = PlannerNotes.actionNote(stepText: planningText, done: done, judgeFeedback: feedback, codeFacts: facts, untypedData: untypedData)
                        result = await plan(note)
                    }
                    guard result.ok else { break }
                    if result.intents.isEmpty { break }
                    done += result.intents
                    executed += result.steps
                    await session.waitUntilScreenSettles()
                    if feedback != nil { break }
                    guard let current = await session.observe() else { break }
                    let complete = await actionsAreComplete(text, done: done, observation: current)
                    Engine.emit(["t": "think", "step": step.number, "phase": "check", "text": complete ? "Every action this step asks for has been performed." : "More actions remain for this step."])
                    if complete { break }
                }
                if session.aborted { break }
            }
            guard let judge else { break }
            await session.waitUntilScreenSettles()
            let expected = text.expected.isEmpty ? text.action : text.expectedAfterAction
            if attempt == 1 { await beforeJudging?() }
            // The screen as it is when it is judged, to tell later whether it moved on.
            let judgedScreen = await session.screenSignature(allowRecent: true)
            var verdict = await session.judgeExpectedResult(judge, number: step.number, stepText: text.action, expected: expected, done: done, attempt: attempt, isLastAttempt: false)
            if !verdict.passed, session.blockedReason == nil {
                if !text.verifiesOnly {
                    // A sheet or menu that is still animating looks wrong for a moment. Look once more, but only when the screen has actually
                    // changed since it was judged: the same screen would get the same verdict, and a model call costs seconds.
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    await session.waitUntilScreenSettles()
                    if await session.screenSignature() != judgedScreen {
                        verdict = await session.judgeExpectedResult(judge, number: step.number, stepText: text.action, expected: expected, done: done, attempt: attempt, isLastAttempt: attempt == maxAttempts)
                    } else if attempt == maxAttempts {
                        session.recordJudgeFailure(number: step.number, expected: expected, reason: verdict.reason, attempt: attempt)
                    }
                } else if attempt == maxAttempts {
                    session.recordJudgeFailure(number: step.number, expected: expected, reason: verdict.reason, attempt: attempt)
                }
            }
            if verdict.passed {
                judgePassed = true
                Engine.reasoning(step: step.number, kind: "decide", "The result is on screen. This step is done.")
                break
            }
            if attempt < maxAttempts {
                Engine.reasoning(step: step.number, kind: "decide", "The expected result is not there yet. Trying a corrective action (attempt \(attempt + 1) of \(maxAttempts)) with \(PlanningTier.choose(attempt: attempt + 1).title).")
            } else {
                Engine.reasoning(step: step.number, kind: "decide", "Out of attempts: the expected result is still not there, so this step fails.")
            }
            feedback = verdict.reason
            prefetch?.cancel()
            // The screen is not what the step expects: before acting again, see what the code says should happen.
            if codeFacts == nil { codeFacts = await consultCode(failure: verdict.reason) }
        }
        if session.aborted { return }
        // The checks on the accessibility tree are supporting evidence: with a judge they run once the judge agrees.
        // (Not for a check-then-act step: its expected result names what was on screen before the action, which the tree no longer shows.)
        if judge != nil, judgePassed, !text.verifiesOnly, !text.expected.isEmpty, !plannedChecks {
            // The judge decided; the quoted labels are looked up in the tree without a model call.
            await session.clock.measure(.check, "Looking for the expected labels on screen") { await runQuickChecks(text) }
        } else if judge == nil || judgePassed, !text.expected.isEmpty || text.verifiesOnly, !(text.verifyThenAct != nil && judgePassed) {
            await session.waitUntilScreenSettles()
            _ = await session.clock.measure(.check, "Planning a check of the screen") {
                await planner.planAndRun(text.verifiesOnly && text.expected.isEmpty ? text.action : "Verify: \(text.expected.isEmpty ? text.action : text.expected)",
                                         phase: "v", note: PlannerNotes.verifyNote, mentioning: text.expected, supporting: judge != nil && judgePassed)
            }
        }
        // Learn only from a step that finished verified: the judge agreed (or there is no judge), nothing failed, and the run is live.
        if let skills, session.mode.isLive, !session.aborted, judge == nil || judgePassed || text.verifiesOnly,
           let pre = preObservation, let post = await session.observe() {
            await session.learnSkill(into: skills, stepNumber: step.number, stepText: step.text, executed: executed, verifiesOnly: text.verifiesOnly, before: pre, after: post)
        }
    }

    /// Looks the step up in the app's source. Returns the facts for the planner and says so in the run log, or nil when there is no repository
    /// or the code has nothing to say about this step.
    private func consultCode(failure: String?) async -> String? {
        guard let codeGuide, !session.aborted else { return nil }
        let text = StepText(step.text)
        let labels = (await session.observe())?.elements.compactMap { $0.label ?? $0.identifier }.filter { !$0.isEmpty } ?? []
        let guide = codeGuide
        let facts = await Task.detached { guide.facts(stepText: text.action, expected: text.expected, failure: failure, screenLabels: labels) }.value
        let message = facts == nil ? "Looked in the app's source for this step: nothing relevant found." : "Read the app's source for this step and planned again with what it shows."
        print("  \(message)")
        // The reasoning shows where the code was found, not the code itself: the planner has the snippets, a person reading the run does not need them.
        let places = (facts ?? "").split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2).prefix(120)) }
        Engine.emit(["t": "think", "step": step.number, "phase": "code", "text": ([message] + places).joined(separator: "\n")])
        return facts
    }

    /// Asks the model whether every action a step calls for has been performed. The answer only decides whether to plan
    /// another round; whatever is planned still goes through grounding, validation and approval like any other step.
    private func actionsAreComplete(_ text: StepText, done: [String], observation: Observation) async -> Bool {
        // A step that names one action, once it has been performed, is complete: no model call needed.
        if !text.isCompound, !done.isEmpty { return true }
        let screen = observation.elements.compactMap { $0.label ?? $0.identifier }.filter { !$0.isEmpty }.prefix(60).joined(separator: " | ")
        guard let answer = try? await llm.sendPrompt(PlannerNotes.completenessPrompt(stepText: text.action, expected: text.expected, done: done, screenLabels: screen)) else { return true }
        return !answer.uppercased().contains("MORE")
    }
}
