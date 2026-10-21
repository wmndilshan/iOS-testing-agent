import Foundation

/// The deterministic status of one proposed, element-specific reference (a target, a scope, or a
/// verification signal's locator/bare identifier) checked against an `ObservedUIVocabulary`.
public enum GroundingStatus: String, Sendable, Equatable, Codable {
    /// Resolves to exactly one real, currently-observed element.
    case grounded
    /// Resolves to two or more real elements — never guessed, never silently first-matched.
    case ambiguous
    /// The proposed identifier/label does not correspond to any real, currently-observed element.
    case unresolved
    /// The reference has no way to resolve an element-specific action at all (e.g. bare role, no
    /// identifier and no label) — a vocabulary-expressiveness gap, not a lookup failure.
    case unsupported
}

/// One grounding decision, always traceable back to the exact IR location it came from.
public struct GroundingIssue: Sendable, Equatable, CustomStringConvertible {
    public let stepID: String
    /// What kind of reference this was (`"target"`, `"scope"`, `"conditionTarget"`, or an `ObservationSignal.name`) — diagnostic only, never influences the status.
    public let kind: String
    public let proposedRole: String?
    public let proposedIdentifier: String?
    public let proposedLabel: String?
    public let status: GroundingStatus
    public let reason: String
    /// The real element's own `id` this reference resolved to — present only when `status == .grounded`.
    public let matchedElementID: String?

    public var description: String { "Step '\(stepID)' (\(kind)): \(status.rawValue) — \(reason)" }
}

/// The full result of grounding one `TestIR` document against one observed snapshot. Bound to that
/// snapshot's ID and is never silently reusable against a different, later snapshot; see
/// `ObservationGroundingService.isCurrent(_:against:)`.
public struct GroundingResult: Sendable, Equatable {
    public let snapshotID: String
    public let issues: [GroundingIssue]

    public init(snapshotID: String, issues: [GroundingIssue]) {
        self.snapshotID = snapshotID
        self.issues = issues
    }

    public var isFullyGrounded: Bool { issues.allSatisfy { $0.status == .grounded } }
    public var blockingIssues: [GroundingIssue] { issues.filter { $0.status != .grounded } }
}

/// Decides whether an LLM-proposed element reference is real. Pure, deterministic, no LLM, no
/// driver, no ToolRegistry, no execution/authorization state — exactly the same purity discipline as
/// `TestIRValidator`/`IRConditionEvaluator`/`SemanticFidelityGate`. This is a SEPARATE responsibility from
/// all three of those:
///   - `TestIRValidator` asks: is the IR structurally/legally well-formed?
///   - `ObservationGroundingService` (this type) asks: does the proposed target actually exist right now?
///   - `SemanticFidelityGate` asks: does the IR represent the requested semantics?
///   - `TrustedActionValidator` (unmodified, protected) asks: is this concrete action currently safe to run?
/// None of these may substitute for another. In particular, this type must never become a second target
/// resolver for dispatch — the trusted spine's own `ScenarioLocator.matches`/`ProposalAdmission` continue to
/// be what actually authorizes a real device action; grounding is a pre-execution advisory gate that BLOCKS
/// before that point, never a bypass or a replacement of it.
public enum ObservationGroundingService {
    /// Mirrors `TestIRValidator`'s own `actionsRequiringSpecificTarget` exactly — the actions whose target
    /// reaches a real device gesture, and therefore the only ones whose `IRTarget` needs grounding. A
    /// `verifyOnly`/branch step carries no target of this kind (see `TestIRValidator.swift`).
    static let groundedActions: Set<IRAction> = [
        .tap, .doubleTap, .longPress, .typeText, .clearText, .navigateBack, .selectTab, .dismissKeyboard, .getElementDetails
    ]

    /// For a step carrying a `branch`, only the condition's own targets are grounded
    /// here — never `thenSteps`/`elseSteps`. Requiring both arms' targets to exist would be wrong: a
    /// branch's whole reason for existing is that the two arms describe two DIFFERENT, mutually exclusive
    /// screen states, so the arm that will NOT run is often legitimately absent from the current
    /// observation. Structural legality of both arms remains `TestIRValidator`'s job (unchanged, still
    /// checks both arms); THIS function answers a narrower question — does the condition's own target
    /// exist? — and leaves "does the selected arm's target exist?" to a SEPARATE call, made once the
    /// runtime (never the LLM) has evaluated the condition against a fresh observation and knows which arm
    /// that is (see `groundSteps` below, called by `StatefulScenarioRunner` on exactly the selected arm's
    /// steps, against a fresh vocabulary).
    public static func ground(ir: TestIR, vocabulary: ObservedUIVocabulary) -> GroundingResult {
        groundSteps(ir.steps, vocabulary: vocabulary)
    }

    /// Grounds exactly this step list. Reusable both for a whole document's top-level steps (`ground(ir:)`
    /// delegates here) and for one specific, already-selected branch arm's steps
    /// `StatefulScenarioRunner` calls this a second time, after condition evaluation, with only the
    /// selected arm and a vocabulary that may be freshly re-captured). Does not descend into an
    /// UNselected arm — see the doc comment on `ground(ir:)`.
    public static func groundSteps(_ steps: [IRStep], vocabulary: ObservedUIVocabulary) -> GroundingResult {
        var issues: [GroundingIssue] = []

        func groundTarget(_ target: IRTarget, stepID: String, kind: String) {
            issues.append(resolve(role: target.role, identifier: target.identifier, label: target.label, stepID: stepID, kind: kind, vocabulary: vocabulary))
            if let scope = target.within {
                issues.append(resolve(role: scope.role, identifier: scope.identifier, label: scope.label, stepID: stepID, kind: "scope", vocabulary: vocabulary))
            }
        }

        // A condition's own target is deliberately never grounded here. Grounding asks "does the
        // proposed DISPATCH target exist right now?" — a question that only makes sense for something about
        // to be acted on. A condition's whole job is to test presence/absence/state, so "the target isn't
        // currently observed" is frequently the CORRECT, intended outcome (elementNotExists, or
        // elementExists evaluating notSatisfied) — not a fabrication. `IRConditionEvaluator` already
        // handles this correctly and deterministically (absent -> notSatisfied for elementExists, ambiguous
        // -> indeterminate, never guessed); grounding must not re-impose a "must currently exist" rule on
        // top of that and turn a legitimate FALSE branch into an incorrectly BLOCKED one. A genuinely
        // fabricated condition target still fails safe: it can only ever read as absent, which
        // `IRConditionEvaluator` turns into a deterministic (if not the tester's intended) branch — it can
        // never reach dispatch, since only the SELECTED arm's own steps are grounded afterward.

        func groundSignal(_ signal: ObservationSignal, stepID: String) {
            switch signal {
            case .elementExists(let loc):
                // "Exists" holds whether one element matches or several (a ticker listed twice, a label on two rows): that is not ambiguity.
                var issue = resolve(role: loc.role, identifier: loc.identifier, label: loc.label, stepID: stepID, kind: signal.name, vocabulary: vocabulary)
                if issue.status == .ambiguous {
                    issue = GroundingIssue(stepID: issue.stepID, kind: issue.kind, proposedRole: issue.proposedRole, proposedIdentifier: issue.proposedIdentifier, proposedLabel: issue.proposedLabel,
                                           status: .grounded, reason: issue.reason + "; for an existence check that is enough", matchedElementID: nil)
                }
                issues.append(issue)
            case .elementAppeared(let loc), .elementDisappeared(let loc), .selectedBecame(let loc):
                issues.append(resolve(role: loc.role, identifier: loc.identifier, label: loc.label, stepID: stepID, kind: signal.name, vocabulary: vocabulary))
            case .labelChanged(let identifier), .valueChanged(let identifier), .navigationBarBecame(let identifier):
                issues.append(resolve(role: nil, identifier: identifier, label: nil, stepID: stepID, kind: signal.name, vocabulary: vocabulary))
            case .labelBecame(let identifier, _):
                issues.append(resolve(role: nil, identifier: identifier, label: nil, stepID: stepID, kind: signal.name, vocabulary: vocabulary))
            case .foregroundApplication, .accessibilitySnapshotChanged, .keyboardBecame:
                break // no element identity proposed; nothing to ground
            }
        }

        func walk(_ steps: [IRStep]) {
            for step in steps {
                if Self.groundedActions.contains(step.action), let target = step.target {
                    groundTarget(target, stepID: step.id, kind: "target")
                }
                if let destination = step.dragDestination { groundTarget(destination, stepID: step.id, kind: "dragDestination") }
                for signal in step.verification?.signals ?? [] {
                    groundSignal(signal, stepID: step.id)
                }
                // A step's own `branch.condition` is deliberately never grounded — see the comment above.
                // Deliberately NOT walking branch.thenSteps/branch.elseSteps here either — see the doc
                // comment on `ground(ir:)`: only the runtime-selected arm is grounded, separately.
            }
        }
        walk(steps)

        return GroundingResult(snapshotID: vocabulary.snapshotID, issues: issues)
    }

    /// The explicit policy for every reference shape:
    ///  1. `role` alone (no identifier, no label) can never resolve an element-specific reference —
    ///     `.unsupported` (a vocabulary-expressiveness gap: role-only cannot select one real element).
    ///  2. An `identifier` is checked FIRST. If it matches exactly one real element (by
    ///     `accessibilityIdentifier`, and — matching `ScenarioLocator`'s own real-world fallback — a real
    ///     element whose *label* equals the proposed identifier also counts, since `tap`'s own resolution
    ///     does the same), that is `.grounded`. Two or more matches: `.ambiguous`. Zero matches: falls
    ///     through to the label-only check below (an identifier that doesn't exist might still be
    ///     resolvable by the accompanying label — but if there is no label either, zero identifier matches
    ///     is `.unresolved`, never silently treated as "try role/label instead").
    ///  3. No identifier, but a `label` (with a role): unique role+label match is `.grounded` — the
    ///     explicit policy Part B point 3 calls for. Zero matches: `.unresolved`. 2+: `.ambiguous`.
    ///  4. `role` is always checked when present: a match must share the proposed role (mirrors
    ///     `ScenarioLocator.matches`'s own hard role equality) — a role mismatch is never silently ignored.
    static func resolve(role: String?, identifier: String?, label: String?, stepID: String, kind: String, vocabulary: ObservedUIVocabulary) -> GroundingIssue {
        func issue(_ status: GroundingStatus, _ reason: String, matched: String? = nil) -> GroundingIssue {
            GroundingIssue(stepID: stepID, kind: kind, proposedRole: role, proposedIdentifier: identifier, proposedLabel: label, status: status, reason: reason, matchedElementID: matched)
        }

        guard (identifier?.isEmpty == false) || (label?.isEmpty == false) else {
            return issue(.unsupported, "role '\(role ?? "any")' alone cannot resolve an element-specific reference — no identifier or label proposed")
        }

        func roleMatches(_ e: ObservedElementReference) -> Bool { role == nil || e.role == role }

        if let identifier, !identifier.isEmpty {
            let byIdentifier = vocabulary.elements.filter { roleMatches($0) && ($0.accessibilityIdentifier == identifier || $0.label == identifier) }
            if byIdentifier.count == 1 { return issue(.grounded, "matched by identifier", matched: byIdentifier[0].elementID) }
            if byIdentifier.count > 1 { return issue(.ambiguous, "identifier '\(identifier)' matches \(byIdentifier.count) real elements") }
            // Zero identifier matches: an accompanying label may still resolve it; otherwise unresolved below.
            if label == nil || label!.isEmpty {
                return issue(.unresolved, "identifier '\(identifier)' does not correspond to any real, currently-observed element")
            }
        }

        if let label, !label.isEmpty {
            let byLabel = vocabulary.elements.filter { roleMatches($0) && $0.label == label }
            if byLabel.count == 1 { return issue(.grounded, "matched by unique role+label", matched: byLabel[0].elementID) }
            if byLabel.count > 1 { return issue(.ambiguous, "label '\(label)' matches \(byLabel.count) real elements of role '\(role ?? "any")'") }
            return issue(.unresolved, "neither the proposed identifier nor label corresponds to any real, currently-observed element")
        }

        return issue(.unresolved, "no real, currently-observed element matches the proposed reference")
    }

    /// A grounding result is bound to exactly one snapshot. Reusing it against a different
    /// snapshot must never be silently accepted — this is a plain, pure equality check, not a new
    /// authorization mechanism; the trusted spine's own `recordObservation`/`ActionProposal.snapshotID`
    /// staleness protection remains the actual, authoritative guard at dispatch time (never duplicated
    /// here).
    public static func isCurrent(_ result: GroundingResult, against vocabulary: ObservedUIVocabulary) -> Bool {
        result.snapshotID == vocabulary.snapshotID
    }
}
