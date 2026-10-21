import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// IR-execution contract: a generic, best-effort observation synthesizer for driving an **arbitrary, not-hand-scripted**
/// compiled `ScenarioStep` through the real trusted spine in simulation. Earlier phases hand-authored the
/// exact pre/post `Observation` for each known step; that doesn't scale to IR whose shape isn't known ahead
/// of time (a real LLM's output, or the full 55-step DEMO-TC-872 fixture run end-to-end in one pass). This
/// type inspects only the step's own locator/verification/signals — data the trusted spine already
/// validated — and manufactures the smallest observation that satisfies them.
///
/// Honesty boundary: `foregroundApplication`, `navigationBarBecame` and `keyboardBecame` depend on live
/// application/keyboard telemetry (`ObservedApplication`) that no synthetic observation fabricates here.
/// Steps relying on one of those signals correctly report `verified: false` — that is the honest outcome of
/// a limitation, not a bug to paper over.
enum IRAutoObserver {
    static let frame = ElementFrame(x: 0, y: 0, width: 100, height: 40)

    static func element(role: String, identifier: String? = nil, label: String? = nil, value: String? = nil,
                         isSelected: Bool? = nil, isEnabled: Bool = true) -> UIElementSnapshot {
        UIElementSnapshot(id: "auto_\(UUID().uuidString.prefix(8))", role: role, label: label, identifier: identifier,
                           value: value, isEnabled: isEnabled, isHittable: true, isSelected: isSelected, frame: frame)
    }

    static func element(for locator: ScenarioLocator, value: String? = nil, isSelected: Bool? = nil) -> UIElementSnapshot {
        element(role: locator.role, identifier: locator.identifier, label: locator.label, value: value, isSelected: isSelected)
    }

    static func element(for expected: ScenarioExpectedElement, isSelected: Bool? = nil) -> UIElementSnapshot {
        element(role: expected.role, identifier: expected.identifier, label: expected.label, isSelected: isSelected, isEnabled: true)
    }

    private static func matches(_ locator: SignalLocator, _ element: UIElementSnapshot) -> Bool {
        if let role = locator.role, element.role != role { return false }
        if let identifier = locator.identifier { return element.identifier == identifier }
        if let label = locator.label { return element.label == label }
        return false
    }

    private static func element(for locator: SignalLocator, value: String? = nil, isSelected: Bool? = nil) -> UIElementSnapshot {
        element(role: locator.role ?? "staticText", identifier: locator.identifier, label: locator.label, value: value, isSelected: isSelected)
    }

    /// Builds a fresh (pre, post) observation pair that satisfies `step.locator` (so admission resolves a
    /// target), every `requiredElements`/`forbiddenElements` entry, and every synthesizable signal. Returns
    /// `honestlyUnsatisfiable`, listing any signal kinds this harness cannot fabricate (never silently
    /// dropped), so the caller can explain a resulting `verified: false` truthfully.
    static func observationPair(for step: ScenarioStep, idPrefix: String) -> (pre: Observation, post: Observation, honestlyUnsatisfiable: [String]) {
        var pre: [UIElementSnapshot] = [element(for: step.locator, isSelected: false)]
        var post: [UIElementSnapshot] = [element(for: step.locator, isSelected: true)]
        var unsatisfiable: [String] = []

        if let verification = step.verification {
            // A requiredElements entry frequently names the same element as the step's own locator (e.g. "the
            // field I just typed into must still satisfy its own requiredElements check") — appending it
            // unconditionally would create a second, indistinguishable element, making later target/signal
            // resolution spuriously ambiguous. Only add it if nothing already present matches.
            for req in verification.requiredElements {
                if !pre.contains(where: { req.matches(element: $0) }) { pre.append(element(for: req)) }
                if !post.contains(where: { req.matches(element: $0) }) { post.append(element(for: req)) }
            }
        }

        // When a signal's bare identifier is the step's own target, its role must stay whatever the
        // locator says (e.g. "secureTextField") — not a generic fallback — or admission's own target
        // resolution (which still requires a role match) breaks.
        func role(forIdentifier identifier: String, fallback: String) -> String {
            step.locator.identifier == identifier ? step.locator.role : fallback
        }

        for signal in step.signals {
            switch signal {
            case .elementExists(let locator):
                pre.append(element(for: locator))
                post.append(element(for: locator))
            case .elementAppeared(let locator):
                // Dedupe on both sides first (a requiredElements entry may already have placed a matching
                // element in pre/post) — otherwise "appeared" ends up with 2 matches in post, which is
                // ambiguous, not "held", exactly like the elementExists ambiguity discipline elsewhere.
                pre.removeAll { matches(locator, $0) }
                post.removeAll { matches(locator, $0) }
                post.append(element(for: locator))
            case .elementDisappeared(let locator):
                pre.removeAll { matches(locator, $0) }
                post.removeAll { matches(locator, $0) }
                pre.append(element(for: locator))
            case .selectedBecame(let locator):
                pre.removeAll { matches(locator, $0) }
                post.removeAll { matches(locator, $0) }
                pre.append(element(for: locator, isSelected: false))
                post.append(element(for: locator, isSelected: true))
            case .labelChanged(let identifier):
                // The identifier this signal names very often coincides with the step's own target (the
                // element you tap/type into is usually the one whose label/value is being asserted to
                // change), which the locator-based add above already placed in pre/post — replace it by
                // identifier rather than appending a second element with the same identifier (which would
                // make the identifier ambiguous and the signal spuriously fail to hold).
                pre.removeAll { $0.identifier == identifier }
                post.removeAll { $0.identifier == identifier }
                let r = role(forIdentifier: identifier, fallback: "staticText")
                pre.append(element(role: r, identifier: identifier, label: "auto_before"))
                post.append(element(role: r, identifier: identifier, label: "auto_after"))
            case .labelBecame(let identifier, let to):
                pre.removeAll { $0.identifier == identifier }
                post.removeAll { $0.identifier == identifier }
                let r = role(forIdentifier: identifier, fallback: "staticText")
                pre.append(element(role: r, identifier: identifier, label: "auto_before"))
                post.append(element(role: r, identifier: identifier, label: to))
            case .valueChanged(let identifier):
                pre.removeAll { $0.identifier == identifier }
                post.removeAll { $0.identifier == identifier }
                let r = role(forIdentifier: identifier, fallback: "textField")
                pre.append(element(role: r, identifier: identifier, value: "auto_before"))
                post.append(element(role: r, identifier: identifier, value: "auto_after"))
            case .accessibilitySnapshotChanged:
                post.append(element(role: "staticText", identifier: "auto_marker_\(UUID().uuidString.prefix(4))"))
            case .foregroundApplication:
                unsatisfiable.append("foregroundApplication (needs real ObservedApplication telemetry)")
            case .navigationBarBecame:
                unsatisfiable.append("navigationBarBecame (needs a real navigationBar role element chain)")
            case .keyboardBecame:
                unsatisfiable.append("keyboardBecame (needs real ObservedKeyboard telemetry)")
            }
        }

        // A forbidden entry always wins, applied last — over the default "the tapped target still exists
        // afterward" assumption and over anything a signal added — e.g. a dismiss button that closes itself
        // is legitimately gone from `post`, even though it's also this step's own tapped target.
        if let verification = step.verification {
            for forb in verification.forbiddenElements { post.removeAll { forb.matches(element: $0) } }
        }

        let preObs = Observation(snapshotID: "\(idPrefix)_pre", bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: pre)
        let postObs = Observation(snapshotID: "\(idPrefix)_post", bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: post)
        return (preObs, postObs, unsatisfiable)
    }

    /// A `verifyOnly` step checks one observation against itself (`pre == post` in
    /// `TestIRExecutor.evaluateVerifyOnly`), so a transition signal can never hold by construction — this
    /// only satisfies `requiredElements`/`forbiddenElements`, which is all a verifyOnly step can honestly use.
    static func observationForVerifyOnly(_ step: ScenarioStep, idPrefix: String) -> Observation {
        var elements: [UIElementSnapshot] = []
        if let verification = step.verification {
            for req in verification.requiredElements { elements.append(element(for: req)) }
        }
        return Observation(snapshotID: "\(idPrefix)_verify", bundleID: "com.apple.mobilesafari", appState: .runningForeground, elements: elements)
    }

    /// Builds elements that make `condition` evaluate to `satisfied` under `IRConditionEvaluator`, for an
    /// arbitrary, not-known-ahead-of-time `IRCondition` (real LLM output or any generalization case). `all`/
    /// `any`/`not` are handled by best-effort recursion (the same target boolean is pushed to every leaf,
    /// except `not` which flips it) — sufficient for a generic simulated-execution proof, not a claim of
    /// exhaustively exercising every boolean combination.
    static func elements(satisfying condition: IRCondition, satisfied: Bool) -> [UIElementSnapshot] {
        switch condition {
        case .elementExists(let target):
            return satisfied ? [element(for: target.locator)] : []
        case .elementNotExists(let target):
            return satisfied ? [] : [element(for: target.locator)]
        case .elementEnabled(let target):
            return [element(role: target.role, identifier: target.identifier, label: target.label, isEnabled: satisfied)]
        case .elementSelected(let target):
            return [element(for: target.locator, isSelected: satisfied)]
        case .elementHasText(let target, let equals):
            return [element(role: target.role, identifier: target.identifier, label: target.label, value: satisfied ? equals : "auto_not_\(equals)")]
        case .applicationStateIs:
            return [] // appState comes from the Observation itself, not an element; caller sets it separately if needed.
        case .all(let cs), .any(let cs):
            return cs.flatMap { elements(satisfying: $0, satisfied: satisfied) }
        case .not(let inner):
            return elements(satisfying: inner, satisfied: !satisfied)
        }
    }

    /// Captured-IR contract: `applicationStateIs` is checked against the `Observation`'s own `appState` field, not an
    /// element — `elements(satisfying:satisfied:)` correctly returns none for it, but that alone left the
    /// caller building every branch-decision observation with a hardcoded `.runningForeground`, so an
    /// `applicationStateIs` condition could never actually be driven to "not satisfied". This finds the
    /// first `applicationStateIs` leaf (recursing through `all`/`any`/`not`, `not` flipping `satisfied` like
    /// `elements(satisfying:)` does) and returns the `AppState` that makes the whole condition evaluate as
    /// `satisfied` states; conditions with no such leaf are unaffected by appState, so `.runningForeground`
    /// (this harness's existing default) is returned unchanged.
    static func appState(for condition: IRCondition, satisfied: Bool) -> AppState {
        switch condition {
        case .applicationStateIs(let expected):
            if satisfied { return expected }
            return expected == .runningForeground ? .runningBackground : .runningForeground
        case .all(let cs), .any(let cs):
            for c in cs {
                if case .applicationStateIs = firstApplicationStateLeaf(c) { return appState(for: c, satisfied: satisfied) }
            }
            return .runningForeground
        case .not(let inner):
            return appState(for: inner, satisfied: !satisfied)
        default:
            return .runningForeground
        }
    }

    private static func firstApplicationStateLeaf(_ condition: IRCondition) -> IRCondition? {
        switch condition {
        case .applicationStateIs: return condition
        case .all(let cs), .any(let cs): return cs.compactMap(firstApplicationStateLeaf).first
        case .not(let inner): return firstApplicationStateLeaf(inner)
        default: return nil
        }
    }
}
