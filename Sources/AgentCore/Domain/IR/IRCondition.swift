import Foundation

/// A closed, strongly-typed condition tree for `IRBranch`. No arbitrary Swift/shell/code can ever be
/// expressed: every leaf is a locator-based predicate over a trusted `Observation`, and the only composition
/// is boolean (`all`/`any`/`not`). `indirect` because `not` holds another `IRCondition` directly.
public indirect enum IRCondition: Codable, Sendable, Equatable {
    case elementExists(IRTarget)
    case elementNotExists(IRTarget)
    case elementEnabled(IRTarget)
    case elementSelected(IRTarget)
    /// The element's recorded `value` equals `equals` exactly (not its label/identifier).
    case elementHasText(IRTarget, equals: String)
    case applicationStateIs(AppState)
    case all([IRCondition])
    case any([IRCondition])
    case not(IRCondition)

    /// A stable name for diagnostics/logs; never influences evaluation.
    public var name: String {
        switch self {
        case .elementExists: "elementExists"
        case .elementNotExists: "elementNotExists"
        case .elementEnabled: "elementEnabled"
        case .elementSelected: "elementSelected"
        case .elementHasText: "elementHasText"
        case .applicationStateIs: "applicationStateIs"
        case .all: "all"
        case .any: "any"
        case .not: "not"
        }
    }
}

/// The result of evaluating an `IRCondition` against one `Observation`. `.indeterminate` is a first-class
/// outcome, not an error swallowed into `false`: an ambiguous or unrecorded predicate must never be guessed.
public enum IRConditionOutcome: Sendable, Equatable {
    case satisfied
    case notSatisfied
    case indeterminate(reason: String)
}

/// Deterministic, no-LLM evaluation of an `IRCondition` against a single, already-fresh `Observation`. Pure:
/// no driver, no tool call, no side effect. Mirrors `ObservationSignal.evaluate`'s discipline (an ambiguous
/// locator match never satisfies a condition).
public enum IRConditionEvaluator {
    public static func evaluate(_ condition: IRCondition, in observation: Observation) -> IRConditionOutcome {
        switch condition {
        case .elementExists(let target):
            switch uniqueMatch(target, in: observation) {
            case .success: return .satisfied
            case .absent: return .notSatisfied
            case .ambiguous(let count): return .indeterminate(reason: "target '\(target.role)/\(target.identifier ?? target.label ?? "?")' matched \(count) elements; a unique match is required")
            }

        case .elementNotExists(let target):
            switch evaluate(.elementExists(target), in: observation) {
            case .satisfied: return .notSatisfied
            case .notSatisfied: return .satisfied
            case .indeterminate(let reason): return .indeterminate(reason: reason)
            }

        case .elementEnabled(let target):
            return resolveUnique(target, in: observation) { $0.isEnabled ? .satisfied : .notSatisfied }

        case .elementSelected(let target):
            return resolveUnique(target, in: observation) { element in
                guard let selected = element.isSelected else { return .indeterminate(reason: "element '\(element.id)' has no recorded selection state") }
                return selected ? .satisfied : .notSatisfied
            }

        case .elementHasText(let target, let equals):
            return resolveUnique(target, in: observation) { $0.value == equals ? .satisfied : .notSatisfied }

        case .applicationStateIs(let expected):
            return observation.appState == expected ? .satisfied : .notSatisfied

        case .all(let conditions):
            var indeterminateReasons: [String] = []
            for c in conditions {
                switch evaluate(c, in: observation) {
                case .satisfied: continue
                case .notSatisfied: return .notSatisfied
                case .indeterminate(let reason): indeterminateReasons.append(reason)
                }
            }
            return indeterminateReasons.isEmpty ? .satisfied : .indeterminate(reason: indeterminateReasons.joined(separator: "; "))

        case .any(let conditions):
            var indeterminateReasons: [String] = []
            for c in conditions {
                switch evaluate(c, in: observation) {
                case .satisfied: return .satisfied
                case .notSatisfied: continue
                case .indeterminate(let reason): indeterminateReasons.append(reason)
                }
            }
            return indeterminateReasons.isEmpty ? .notSatisfied : .indeterminate(reason: indeterminateReasons.joined(separator: "; "))

        case .not(let inner):
            switch evaluate(inner, in: observation) {
            case .satisfied: return .notSatisfied
            case .notSatisfied: return .satisfied
            case .indeterminate(let reason): return .indeterminate(reason: reason)
            }
        }
    }

    private enum MatchResult { case success(UIElementSnapshot); case absent; case ambiguous(Int) }

    /// When `target.within` is present, matches are further restricted to elements
    /// that are DESCENDANTS (via the real, already-populated `UIElementSnapshot.parentID` chain — no new
    /// telemetry, no coordinates) of a uniquely-resolved scope element. If the scope itself doesn't resolve
    /// to exactly one element (absent OR ambiguous), the result is always `.ambiguous` here — never
    /// `.absent` — so every caller treats it as INDETERMINATE ("we cannot know") rather than a confident
    /// "does not exist"; a missing container is not evidence the target itself is absent, it just means the
    /// search space could never be established, and this must never be guessed either way.
    private static func uniqueMatch(_ target: IRTarget, in observation: Observation) -> MatchResult {
        var matches = observation.elements.filter { target.locator.matches(element: $0) }
        if let scope = target.within {
            let scopeMatches = observation.elements.filter { scope.asTarget.locator.matches(element: $0) }
            guard scopeMatches.count == 1 else {
                return .ambiguous(scopeMatches.count)
            }
            let scopeID = scopeMatches[0].id
            matches = matches.filter { isDescendant($0, ofElementID: scopeID, in: observation) }
        }
        switch matches.count {
        case 0: return .absent
        case 1: return .success(matches[0])
        default: return .ambiguous(matches.count)
        }
    }

    /// Walks `parentID` upward from `element` looking for `ancestorID`. Bounded (`maxHops`) so a malformed
    /// or cyclic parent chain in the observation data can never hang; an unresolvable chain (missing parent,
    /// hop limit reached) simply means "not a descendant", never a crash or an infinite loop.
    private static func isDescendant(_ element: UIElementSnapshot, ofElementID ancestorID: String, in observation: Observation, maxHops: Int = 20) -> Bool {
        var current = element
        var hops = 0
        while let parentID = current.parentID, hops < maxHops {
            if parentID == ancestorID { return true }
            guard let parent = observation.elements.first(where: { $0.id == parentID }) else { return false }
            current = parent
            hops += 1
        }
        return false
    }

    private static func resolveUnique(_ target: IRTarget, in observation: Observation, _ body: (UIElementSnapshot) -> IRConditionOutcome) -> IRConditionOutcome {
        switch uniqueMatch(target, in: observation) {
        case .success(let element): return body(element)
        case .absent: return .indeterminate(reason: "target '\(target.role)/\(target.identifier ?? target.label ?? "?")' is absent; this predicate requires the element to exist")
        case .ambiguous(let count): return .indeterminate(reason: "target '\(target.role)/\(target.identifier ?? target.label ?? "?")' matched \(count) elements; a unique match is required")
        }
    }
}
