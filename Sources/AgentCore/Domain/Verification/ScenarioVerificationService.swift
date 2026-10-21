import Foundation

/// Trusted, deterministic verification of a step against a FRESH post-action observation.
///
/// Verification is native Swift evaluation of rules owned by `ScenarioCatalog`. No LLM, skill or
/// caller-supplied value can influence the outcome, and a mutating step without an explicit rule
/// never defaults to verified (fail-closed).
public struct ScenarioVerificationService: Sendable {

    public init() {}

    public func verify(
        step: ScenarioStep,
        scenario: SafeScenario,
        observation: Observation,
        pre: Observation? = nil
    ) -> ScenarioVerificationResult {
        // Declared transition signals are checked first; each needs both fresh observations and all must hold.
        if !step.signals.isEmpty {
            guard let pre else {
                return ScenarioVerificationResult(verified: false, reason: "Step '\(step.name)' declares transition signals but no fresh pre-action observation was supplied.")
            }
            for signal in step.signals {
                let outcome = signal.evaluate(pre: pre, post: observation)
                if !outcome.held { return ScenarioVerificationResult(verified: false, reason: "Signal \(signal.name) did not hold: \(outcome.reason)") }
            }
        }
        if let verification = step.verification {
            return verification.verify(in: observation)
        }
        if !scenario.changesUIState {
            let hasAll = scenario.expectedElements.allSatisfy { expected in
                observation.elements.contains(where: { expected.matches(element: $0) })
            }
            return ScenarioVerificationResult(
                verified: hasAll,
                reason: hasAll ? "All expected baseline elements verified unchanged." : "Screen state unconfirmed."
            )
        }
        return ScenarioVerificationResult(
            verified: false,
            reason: "Fail-Closed Verification: Mutating step '\(step.name)' lacks an explicit verification rule in ScenarioCatalog."
        )
    }
}
