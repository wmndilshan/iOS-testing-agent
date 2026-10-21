import Foundation

/// The result of proposing the controller's current compiled step against a fresh observation.
public enum TestIRProposalOutcome: Sendable {
    case pending(HITLApprovalRequest)
    case rejected(reason: String)
    case noActiveStep
    case noMatchingElement(stepID: String)
}

/// A generic, structural decomposition of any `[IRStep]` list into runnable pieces: a leading run of
/// non-branching steps (safe to compile into one `SafeScenario` and run linearly), or a single branch node
/// that must be decided before anything after it can be known. Purely positional — no step id, source AIO
/// step number, or test identity is ever inspected — so it applies identically to a top-level `TestIR.steps`
/// list, a chosen `IRBranch` arm, or a nested arm at any depth.
public enum IRExecutionSegment: Sendable {
    case linear(steps: [IRStep], remaining: [IRStep])
    case branch(IRBranch, sourceStepID: String, remaining: [IRStep])
    case done
}

public enum IRBranchArm: Sendable, Equatable { case then, `else` }

/// The result of deciding one `IRBranch` against a fresh observation.
public enum IRBranchSelectionOutcome: Sendable, Equatable {
    case selected(arm: IRBranchArm, snapshotID: String)
    /// The condition could not be deterministically evaluated (ambiguous/unrecorded state). Execution must
    /// stop here — never guess an arm.
    case indeterminate(reason: String)
}

/// Compiles a validated `TestIR` into a runnable `SafeScenario` and gets it as far as a pending human
/// approval on the **one existing, sanctioned** execution path — `ScenarioExecutionController`
/// (`recordObservation` -> `handleProposal`) — instead of a second, parallel one.
///
/// This type deliberately stops at the pending `HITLApprovalRequest`. It never calls
/// `controller.approveCurrentStep()` or `controller.dispatchCurrentStep(...)` itself, and never
/// instantiates `ScenarioStepDispatcher` or calls `ToolRegistry.execute`/`executeReadOnly` directly: this
/// repo's own architecture audit (`TrustedSpineAuditTests`, `WorkflowArchitectureTests`) restricts those
/// calls to the controller itself, `AgentUIState` and the CLI runner — the same small, audited set of
/// entry points a *real* human approval or an explicitly mode-gated automated run would come through. An IR
/// layer sitting above the trusted boundary must not manufacture a new approval/dispatch call site just
/// because simulating one is convenient; a caller that wants to simulate approval (tests do,
/// since nothing here runs live) calls the controller's own `approveCurrentStep()`/`dispatchCurrentStep()`
/// directly, exactly as `AgentUIState` does today, never through this type.
@MainActor
public struct TestIRExecutor {
    public let controller: ScenarioExecutionController

    public init(controller: ScenarioExecutionController) {
        self.controller = controller
    }

    /// Compiles every step `TestIRValidator` admitted (`.admitted`) into a `ScenarioStep`, in document
    /// order, and wraps them in one `SafeScenario` ready for `controller.startScenario(_:)`. Branch arms are
    /// not flattened here — the simulated executor runs a linear, non-branching sequence; branch
    /// *shape* is still fully validated and compiled by `TestIRCompiler` on its own, per step, independent
    /// of this convenience. Returns `nil` if nothing admitted compiled.
    public static func compileLinearScenario(
        testKey: String, title: String, steps: [IRStep], verdicts: [String: IRStepVerdict],
        credentials: [String: String] = ProcessInfo.processInfo.environment
    ) -> SafeScenario? {
        let compiled: [ScenarioStep] = steps.compactMap { step -> ScenarioStep? in
            guard case .admitted = verdicts[step.id] else { return nil }
            guard case .compiled(let c) = TestIRCompiler.compile(step, credentials: credentials) else { return nil }
            return c.scenarioStep
        }
        guard !compiled.isEmpty else { return nil }
        return SafeScenario(
            id: testKey, name: title, purpose: "Compiled from a validated TestIR document.",
            initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, steps: compiled
        )
    }

    /// Splits `steps` at its first branch node: everything before it is one linear run; the branch node
    /// itself (and everything the caller supplies as "after it") is handled by `evaluateBranch` plus a
    /// recursive re-entry into whichever arm gets selected. Purely structural — see the type doc comment.
    public static func nextSegment(_ steps: [IRStep]) -> IRExecutionSegment {
        guard let first = steps.first else { return .done }
        if let branch = first.branch {
            return .branch(branch, sourceStepID: first.id, remaining: Array(steps.dropFirst()))
        }
        let linear = steps.prefix { $0.branch == nil }
        return .linear(steps: Array(linear), remaining: Array(steps.dropFirst(linear.count)))
    }

    /// Decides one `IRBranch` against a fresh observation. Binds/freshens that observation into the
    /// controller exactly as any other step would (`recordObservation` invalidates a stale pending approval
    /// bound to an older snapshot), then evaluates the condition deterministically — no LLM, no tool call,
    /// no driver access. This is the *only* thing a branch step does; selecting an arm never executes it —
    /// the caller must still compile and propose the chosen arm's steps through the normal pipeline.
    public func evaluateBranch(_ branch: IRBranch, freshObservation: Observation) -> IRBranchSelectionOutcome {
        controller.recordObservation(freshObservation)
        switch IRConditionEvaluator.evaluate(branch.condition, in: freshObservation) {
        case .satisfied: return .selected(arm: .then, snapshotID: freshObservation.snapshotID)
        case .notSatisfied: return .selected(arm: .else, snapshotID: freshObservation.snapshotID)
        case .indeterminate(let reason): return .indeterminate(reason: reason)
        }
    }

    /// Records a fresh observation and proposes the controller's current compiled step against it — the
    /// same shape a real LLM proposal would take (a target resolved from the trusted step's own locator,
    /// never invented). Stops at the resulting pending approval; approving and dispatching are the caller's
    /// job (see the type-level note on why this type never does either itself).
    public func proposeCurrentStep(freshObservation: Observation) -> TestIRProposalOutcome {
        controller.recordObservation(freshObservation)
        guard let step = controller.activeStep else { return .noActiveStep }
        guard let element = freshObservation.elements.first(where: { step.locator.matches(element: $0) }) else {
            return .noMatchingElement(stepID: step.id)
        }
        let proposal = ActionProposal(
            scenarioID: controller.activeScenario?.id ?? "", snapshotID: freshObservation.snapshotID, elementID: element.id,
            expectedRole: element.role, expectedIdentifier: element.identifier ?? element.label,
            toolName: step.toolName, arguments: [:], reason: step.description,
            stepIndex: controller.currentStepIndex, stepID: step.id
        )
        switch controller.handleProposal(proposal) {
        case .success(let approval): return .pending(approval)
        case .failure(let error): return .rejected(reason: error.localizedDescription)
        }
    }

    /// Evaluates a `.verifyOnly` step's verification directly against a fresh observation — no
    /// `ActionProposal`, no approval, no dispatch. A `verifyOnly` step performs no device action (its
    /// underlying tool, `get_accessibility_tree`, only reads); unlike a mutating step it has no target
    /// element to resolve via `proposeCurrentStep`, so it is decided the same way a branch is: a pure,
    /// deterministic check against the observation the caller already holds, never a new device call. This
    /// still binds the observation into the controller (`recordObservation`) so the same freshness/staleness
    /// bookkeeping applies as everywhere else.
    public func evaluateVerifyOnly(_ step: IRStep, freshObservation: Observation) -> ScenarioVerificationResult? {
        guard step.action == .verifyOnly else { return nil }
        controller.recordObservation(freshObservation)
        guard case .compiled(let compiled) = TestIRCompiler.compile(step) else {
            return ScenarioVerificationResult(verified: false, reason: "step '\(step.id)' did not compile")
        }
        let scenario = SafeScenario(
            id: controller.activeScenario?.id ?? step.id, name: "verify-only", purpose: "Direct verifyOnly check.",
            initialStateRequirement: "", expectedPostActionState: "", changesUIState: false, actionStep: compiled.scenarioStep
        )
        return ScenarioVerificationService().verify(step: compiled.scenarioStep, scenario: scenario, observation: freshObservation, pre: freshObservation)
    }
}
