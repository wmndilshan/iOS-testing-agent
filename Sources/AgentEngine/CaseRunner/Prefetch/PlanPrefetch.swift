import Foundation
import AgentCore
import AgentInfrastructure

/// Plans the next step's first action while the current step is being judged, as a person reads the next instruction while checking the screen.
/// A prefetched plan is only a `TestIR`: nothing is dispatched. It is used when the judge passes and the screen the next step starts on is still
/// the one it was planned on; otherwise it is thrown away. Grounding, validation and approval happen at execution as for any plan.
@MainActor
final class PlanPrefetch {
    /// How much of the screen must be the same for a prefetched plan to be used (share of identifiers in common, see `ScreenSignature`).
    static let minimumSimilarity = 0.9

    private struct Entry {
        let step: Int
        let screen: ScreenSignature
        let task: Task<GroundedGenerationOutcome, Never>
    }

    private var entry: Entry?

    /// Starts planning `step` against `observation`. Replaces an earlier, unused prefetch.
    func start(step: Int, observation: Observation, plan: @escaping @MainActor (Observation) async -> GroundedGenerationOutcome) {
        cancel()
        entry = Entry(step: step, screen: ScreenSignature(from: observation), task: Task { @MainActor in await plan(observation) })
    }

    /// The prefetched plan for `step`, if there is one and `current` is still the screen it was planned on. It is used once.
    func take(step: Int, current: Observation) async -> GroundedGenerationOutcome? {
        guard let entry, entry.step == step else { cancel(); return nil }
        self.entry = nil
        guard Self.isReusable(plannedOn: entry.screen, current: ScreenSignature(from: current)) else {
            entry.task.cancel()
            return nil
        }
        let outcome = await entry.task.value
        // A plan that could not be grounded was made by the fast model alone: the normal path (which may escalate) must get its turn.
        if case .blocked = outcome { return nil }
        return outcome
    }

    /// Drops a prefetch that will not be used (the judge disagreed, or the run stopped).
    func cancel() {
        entry?.task.cancel()
        entry = nil
    }

    static func isReusable(plannedOn: ScreenSignature, current: ScreenSignature) -> Bool {
        plannedOn.similarity(to: current) >= minimumSimilarity
    }

    /// Whether a step's first action is worth planning ahead: it has an action round, needs no secret and no person, and is a plain step
    /// (a check-then-act step is checked on the screen as it is first).
    static func isEligible(_ stepText: String) -> Bool {
        let text = StepText(stepText)
        return !text.verifiesOnly && text.verifyThenAct == nil && !stepText.contains("[CREDENTIALS]") && !stepText.lowercased().contains("username")
    }
}
