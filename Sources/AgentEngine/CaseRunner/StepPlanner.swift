import Foundation
import AgentCore
import AgentInfrastructure

/// What planning and running one piece of a step produced.
struct PlanRunResult {
    let ok: Bool
    let intents: [String]
    let steps: [IRStep]
    /// Why nothing could be planned or run, when it is known (what the screen lacked).
    var reason = ""
    static let failed = PlanRunResult(ok: false, intents: [], steps: [])
}

/// Plans one piece of a case step against the live screen, brings a scrolled-off target into view when needed, and runs it.
@MainActor
struct StepPlanner {
    let session: CaseRunSession
    /// The model chosen for action planning, and the fast one. Result checks are short and simple, so they use the fast model;
    /// an action plan tries the fast model first and escalates to the strong one when its plan is rejected or the judge disagreed.
    let strongLLM: any LLMClientProtocol
    let fastLLM: any LLMClientProtocol
    let step: CaseStep
    let startStep: Int
    /// A plan made ahead while the previous step was judged; used for this step's first action when the screen is still the same.
    var prefetch: PlanPrefetch? = nil

    /// Returns `ok == false` when the step could not be planned or one of its steps failed.
    func planAndRun(_ text: String, phase: String, note: String, mentioning: String, actionsOnly: Bool = false, tentative: Bool = false, previous: IRStep? = nil, tier: PlanningTier = .escalating, supporting: Bool = false, usePrefetch: Bool = false) async -> PlanRunResult {
        guard let observation = await session.observe() else {
            session.recordRow("\(step.number).\(phase)plan", number: step.number, intent: text, action: "plan", .failed, "fresh observation failed; nothing planned")
            return .failed
        }
        if phase != "v" {
            let labels = Array(NSOrderedSet(array: observation.elements.compactMap { $0.label }.filter { !$0.isEmpty && $0.count <= 28 }).array.prefix(7)) as? [String] ?? []
            Engine.reasoning(step: step.number, kind: "observe", "Read the screen: \(observation.elements.count) elements" + (labels.isEmpty ? "." : ", for example " + labels.joined(separator: ", ") + "."))
        }
        var outcome: GroundedGenerationOutcome
        if usePrefetch, let prefetch, let ready = await prefetch.take(step: step.number, current: observation) {
            print("  Using the plan made while the previous step was being judged.")
            Engine.reasoning(step: step.number, kind: "plan", "Using the plan prepared while the previous step was being judged: the screen is the same.")
            outcome = ready
        } else {
            if phase != "v" { Engine.activity(step: step.number, kind: "plan", "Asking \(tier.title) what to do next") }
            outcome = await plan(text, note: note, observation: observation, verifying: phase == "v", tier: tier)
        }
        // A target that is in the accessibility tree but scrolled out of view is brought into view, then planned again.
        var reveals = 0
        while case .blocked = outcome, reveals < 6, !session.aborted {
            guard let current = await session.observe(),
                  await session.revealOffscreenTarget(mentionedIn: mentioning, observation: current, number: step.number, attempt: reveals + 1),
                  let fresh = await session.observe() else { break }
            reveals += 1
            outcome = await plan(text, note: note, observation: fresh, verifying: phase == "v", tier: tier)
        }
        switch outcome {
        case .accepted(let planned, _):
            session.saveGeneratedIR(planned, number: step.number, attempt: reveals + 1, phase: phase)
            let ir = actionsOnly ? actionsOnlyDocument(planned) : planned
            // The same action again is never useful: the first one either worked or the judge will say what is missing.
            if actionsOnly, let first = ir.steps.first, let previous, first.action == previous.action, first.target == previous.target {
                Engine.emit(["t": "think", "step": step.number, "phase": phase, "text": "The plan repeats the previous action; moving on to the check."])
                return PlanRunResult(ok: true, intents: [], steps: [])
            }
            Engine.reasoning(step: step.number, kind: "plan",
                                             ir.steps.isEmpty ? "The plan has no further action for this step." : "Plan: " + ir.steps.map(\.intent).joined(separator: " → "))
            if ir.steps.isEmpty { return PlanRunResult(ok: true, intents: [], steps: []) }
            // The target can exist in the tree yet be scrolled out of view; scroll it into view before acting on it.
            if actionsOnly, let target = ir.steps.first?.target {
                var scrolls = 0
                while scrolls < 6, !session.aborted, let current = await session.observe(), session.isOffscreen(target, in: current),
                      await session.revealOffscreenTarget(mentionedIn: "", exactTarget: target, observation: current, number: step.number, attempt: scrolls + 1) {
                    scrolls += 1
                }
            }
            if let first = ir.steps.first { Engine.activity(step: step.number, kind: "act", "Doing: \(first.intent)") }
            let ok = await session.runDocument(ir: ir, rowPrefix: "\(step.number).\(phase)", stepNumber: step.number, startStep: startStep, humanNumbers: [], tentative: tentative)
            return PlanRunResult(ok: ok, intents: ir.steps.map(\.intent), steps: ir.steps)
        case .blocked(let reason, let attempts):
            let issues = (attempts.last?.grounding?.blockingIssues ?? []).map(\.description).prefix(3).joined(separator: "; ")
            let detail = "could not ground this on the live screen: \(reason)\(issues.isEmpty ? "" : " [\(issues)]")"
            // A supporting check that cannot be built (a label that matches two elements, for example) is no evidence against a result the
            // judge has already confirmed from the screenshot: record it as skipped, not failed.
            let bestEffort = supporting || tentative
            session.recordRow("\(step.number).\(phase)plan", number: step.number, intent: text, action: "plan", bestEffort ? .skipped : .failed,
                              bestEffort ? "no further action or check could be built here; the judge decides the result. \(detail)" : detail)
            // A follow-up action (a second round, or a retry after the judge) is best effort: when it cannot be planned, the screen goes to
            // the judge. Only the first action of a step must be plannable.
            return bestEffort ? PlanRunResult(ok: tentative ? false : true, intents: [], steps: [], reason: detail) : PlanRunResult(ok: false, intents: [], steps: [], reason: detail)
        }
    }

    /// The first fast plan of a step, made ahead of time (see `PlanPrefetch`).
    func planAhead(_ text: String, note: String, observation: Observation) async -> GroundedGenerationOutcome {
        await plan(text, note: note, observation: observation, tier: .fast)
    }

    private func plan(_ text: String, note: String, observation: Observation, verifying: Bool = false, tier: PlanningTier = .escalating) async -> GroundedGenerationOutcome {
        let client: any LLMClientProtocol
        switch (verifying, tier) {
        case (true, _), (false, .fast): client = fastLLM
        // Two fast tries (the second one is shown why the first was rejected), then the strong model.
        case (false, .escalating): client = EscalatingLLMClient(fast: fastLLM, strong: strongLLM, strongFrom: 2)
        case (false, .strong): client = strongLLM
        }
        return await GroundedTestIRGeneration.generate(using: TestIRGenerator(llmClient: client), testKey: session.key, title: session.title,
                                                stepsText: "\(step.number). \(text)\n\(note)\n\(session.guidance.promptBlock)\n\(PlannerNotes.environment)",
                                                vocabulary: ObservedUIVocabulary.derive(from: PlannerNotes.withoutSharedIdentifiers(PlannerNotes.withoutUnrelatedFloaters(observation, for: text)))).outcome
    }

    /// The action phase runs actions only; the expected result is checked in the next phase against the new screen.
    /// One action per round: a second action would be planned against a screen that does not exist yet.
    private func actionsOnlyDocument(_ planned: TestIR) -> TestIR {
        TestIR(testKey: planned.testKey, title: planned.title, steps: Array(planned.steps.filter { $0.action != .verifyOnly }.prefix(1)).map { action in
            // An action is confirmed by "dispatched, and the app is still in front". Demanding that the tree changed would fail a
            // valid action that changes nothing (choosing an option that is already selected); the result is checked in the next phase.
            IRStep(id: action.id, sourceStepNumber: action.sourceStepNumber, intent: action.intent, action: action.action, target: action.target,
                   arguments: action.arguments, credentialRef: action.credentialRef, wait: action.wait, branch: action.branch,
                   verification: action.action == .waitForElement ? action.verification
                       : IRVerification(description: "action dispatched and the application is still in the foreground", signals: [.foregroundApplication(bundleID: session.bundleID)]))
        })
    }
}
