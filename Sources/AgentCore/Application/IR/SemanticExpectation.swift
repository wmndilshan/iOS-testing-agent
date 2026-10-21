import Foundation

/// A small, deterministic description of the intent-bearing facts a natural-language test case
/// implies — written by hand from the NL text, independently of any generated IR (which never retains its
/// own source NL — see `TestIR.fieldNames`). This is NOT another IR: it names no steps, no targets to act
/// on, no order, nothing executable. It only records the handful of structural properties
/// `SemanticFidelityGate` can deterministically check against a real generated `TestIR` value.
public struct SemanticExpectation: Codable, Sendable, Equatable {
    public let caseID: String
    /// `IRAction.rawValue`s that must appear at least once in the generated document.
    public let expectedActions: Set<String>
    /// `IRAction.rawValue`s that must never appear.
    public let forbiddenActions: Set<String>
    /// `IRCondition.name`s that must appear at least once in the branch-condition tree.
    public let expectedConditionKinds: Set<String>
    /// `IRCondition.name`s that must never appear in the branch-condition tree.
    public let forbiddenConditionKinds: Set<String>
    /// `ObservationSignal.name`s that must appear at least once in some step's `verification.signals`.
    public let expectedSignalKinds: Set<String>
    /// `nil` means "don't care"; otherwise the exact number of branch nodes (steps with `branch != nil`,
    /// counted recursively through nested arms) the document is expected to contain.
    public let expectedBranchCount: Int?
    /// Literal text values expected to appear somewhere relevant (an `elementHasText` condition's `equals`,
    /// a `typeText` step's `"text"` argument, or a `labelBecame` signal's `to`) — a simple presence check,
    /// not a full text/NLP model.
    public let requiredTextValues: Set<String>
    /// Whether at least one step must carry a `credentialRef` (a credential must never appear as literal text).
    public let requiresCredentialRef: Bool
    /// Labels or identifiers that must appear as some step's
    /// `target.label`/`target.identifier` (or a `requiredElements`/`forbiddenElements` entry's, since a
    /// verifyOnly step names its target that way instead). A simple presence check over the exact NL-named
    /// entity — not a positional/ordinal resolver ("the second X"), which this gate deliberately does not
    /// attempt because the IR vocabulary does not represent ordinal or positional semantics.
    public let requiredTargetLabels: Set<String>
    /// Whether every admitted, non-`verifyOnly` step is
    /// required to carry a non-nil `verification` naming at least one checkable `requiredElements` entry or
    /// `signals` entry — set when the NL explicitly demands a post-condition ("...and verify X appears").
    public let requiresVerificationPresence: Bool
    /// Labels or identifiers that must appear as some target's `within.label`/
    /// `within.identifier` — i.e. the NL named a container, and the generated IR must actually scope the
    /// target to it (not just name the target itself, as `requiredTargetLabels` alone would confirm).
    public let requiredTargetScopeLabels: Set<String>

    public init(
        caseID: String, expectedActions: Set<String> = [], forbiddenActions: Set<String> = [],
        expectedConditionKinds: Set<String> = [], forbiddenConditionKinds: Set<String> = [],
        expectedSignalKinds: Set<String> = [], expectedBranchCount: Int? = nil,
        requiredTextValues: Set<String> = [], requiresCredentialRef: Bool = false,
        requiredTargetLabels: Set<String> = [], requiresVerificationPresence: Bool = false,
        requiredTargetScopeLabels: Set<String> = []
    ) {
        self.caseID = caseID
        self.expectedActions = expectedActions
        self.forbiddenActions = forbiddenActions
        self.expectedConditionKinds = expectedConditionKinds
        self.forbiddenConditionKinds = forbiddenConditionKinds
        self.expectedSignalKinds = expectedSignalKinds
        self.expectedBranchCount = expectedBranchCount
        self.requiredTextValues = requiredTextValues
        self.requiresCredentialRef = requiresCredentialRef
        self.requiredTargetLabels = requiredTargetLabels
        self.requiredTargetScopeLabels = requiredTargetScopeLabels
        self.requiresVerificationPresence = requiresVerificationPresence
    }
}

// MARK: - Gate

public enum SemanticFidelityClassification: String, Sendable, Equatable {
    case exactMatch = "EXACT_MATCH"
    case semanticMismatch = "SEMANTIC_MISMATCH"
}

public struct SemanticMismatchDetail: Sendable, Equatable, CustomStringConvertible {
    public let property: String
    public let expected: String
    public let actual: String
    public var description: String { "\(property): expected \(expected), got \(actual)" }
}

public struct SemanticFidelityResult: Sendable, Equatable {
    public let classification: SemanticFidelityClassification
    public let mismatches: [SemanticMismatchDetail]
}

/// A small, pure, deterministic comparison of `expectation` with an already-decoded, already-
/// validated `TestIR` value already sitting in memory. Never touches a driver, `ToolRegistry`,
/// `ScenarioExecutionController`, or anything execution-adjacent; never approves, dispatches, or produces a
/// snapshot/observation/authorization identifier of any kind (there is nothing here that could — every input
/// and output type in this file is a plain value, Sendable, with no side-effecting dependency). See
/// `SemanticGateSecurityBoundaryTests` for the structural proof.
public enum SemanticFidelityGate {
    public static func evaluate(expectation: SemanticExpectation, against ir: TestIR) -> SemanticFidelityResult {
        let flat = flattenSteps(ir.steps)
        let actions = Set(flat.map(\.action.rawValue))
        let conditionKindSet = Set(allConditionKinds(in: ir.steps))
        let signalKindSet = Set(flat.compactMap(\.verification).flatMap(\.signals).map(\.name))
        let branchCount = countBranchNodes(ir.steps)
        let textValues = allTextValues(in: ir.steps)
        let hasCredentialRef = flat.contains { $0.credentialRef != nil }

        var mismatches: [SemanticMismatchDetail] = []

        for expected in expectation.expectedActions.sorted() where !actions.contains(expected) {
            mismatches.append(SemanticMismatchDetail(property: "expectedAction", expected: expected, actual: "absent (found: \(actions.sorted().joined(separator: ", ")))"))
        }
        for forbidden in expectation.forbiddenActions.sorted() where actions.contains(forbidden) {
            mismatches.append(SemanticMismatchDetail(property: "forbiddenAction", expected: "absent", actual: forbidden))
        }
        for expected in expectation.expectedConditionKinds.sorted() where !conditionKindSet.contains(expected) {
            mismatches.append(SemanticMismatchDetail(property: "expectedConditionKind", expected: expected, actual: "absent (found: \(conditionKindSet.sorted().joined(separator: ", ")))"))
        }
        for forbidden in expectation.forbiddenConditionKinds.sorted() where conditionKindSet.contains(forbidden) {
            mismatches.append(SemanticMismatchDetail(property: "forbiddenConditionKind", expected: "absent", actual: forbidden))
        }
        for expected in expectation.expectedSignalKinds.sorted() where !signalKindSet.contains(expected) {
            mismatches.append(SemanticMismatchDetail(property: "expectedSignalKind", expected: expected, actual: "absent (found: \(signalKindSet.sorted().joined(separator: ", ")))"))
        }
        if let expectedBranchCount = expectation.expectedBranchCount, expectedBranchCount != branchCount {
            mismatches.append(SemanticMismatchDetail(property: "expectedBranchCount", expected: "\(expectedBranchCount)", actual: "\(branchCount)"))
        }
        for text in expectation.requiredTextValues.sorted() where !textValues.contains(text) {
            mismatches.append(SemanticMismatchDetail(property: "requiredTextValue", expected: text, actual: "absent (found: \(textValues.sorted().joined(separator: ", ")))"))
        }
        if expectation.requiresCredentialRef && !hasCredentialRef {
            mismatches.append(SemanticMismatchDetail(property: "requiresCredentialRef", expected: "at least one credentialRef", actual: "none present"))
        }
        let targetLabels = allTargetLabels(in: ir.steps)
        for label in expectation.requiredTargetLabels.sorted() where !targetLabels.contains(label) {
            mismatches.append(SemanticMismatchDetail(property: "requiredTargetLabel", expected: label, actual: "absent (found: \(targetLabels.sorted().joined(separator: ", ")))"))
        }
        let scopeLabels = allTargetScopeLabels(in: ir.steps)
        for label in expectation.requiredTargetScopeLabels.sorted() where !scopeLabels.contains(label) {
            mismatches.append(SemanticMismatchDetail(property: "requiredTargetScopeLabel", expected: label, actual: "absent (found: \(scopeLabels.sorted().joined(separator: ", ")))"))
        }
        if expectation.requiresVerificationPresence {
            // The NL's postcondition only needs to be checkable SOMEWHERE in the sequence — a compound
            // instruction ("tap Add Symbols, then verify the search field appears") is correctly represented
            // by a precursor action step plus a separate verifyOnly/verification step; requiring every
            // individual step to carry its own checkable verification would be stricter than the NL itself.
            let hasCheckable = flat.contains { step in
                guard let v = step.verification else { return false }
                return !v.requiredElements.isEmpty || !v.forbiddenElements.isEmpty || !v.signals.isEmpty
            }
            if !hasCheckable {
                mismatches.append(SemanticMismatchDetail(property: "requiresVerificationPresence", expected: "at least one step has a checkable requiredElement/forbiddenElement/signal", actual: "none present"))
            }
        }

        return SemanticFidelityResult(classification: mismatches.isEmpty ? .exactMatch : .semanticMismatch, mismatches: mismatches)
    }

    // MARK: - structural helpers (read-only; never mutate, never call anything execution-adjacent)

    static func flattenSteps(_ steps: [IRStep]) -> [IRStep] {
        steps.flatMap { step -> [IRStep] in
            var out = [step]
            if let branch = step.branch { out += flattenSteps(branch.thenSteps) + flattenSteps(branch.elseSteps) }
            return out
        }
    }

    static func countBranchNodes(_ steps: [IRStep]) -> Int {
        steps.reduce(0) { count, step in
            guard let branch = step.branch else { return count }
            return count + 1 + countBranchNodes(branch.thenSteps) + countBranchNodes(branch.elseSteps)
        }
    }

    static func allConditionKinds(in steps: [IRStep]) -> [String] {
        func kinds(_ condition: IRCondition) -> [String] {
            switch condition {
            case .all(let cs), .any(let cs): [condition.name] + cs.flatMap(kinds)
            case .not(let c): [condition.name] + kinds(c)
            default: [condition.name]
            }
        }
        return steps.flatMap { step -> [String] in
            guard let branch = step.branch else { return [] }
            return kinds(branch.condition) + allConditionKinds(in: branch.thenSteps) + allConditionKinds(in: branch.elseSteps)
        }
    }

    static func allTextValues(in steps: [IRStep]) -> Set<String> {
        var values: Set<String> = []
        func visit(_ steps: [IRStep]) {
            for step in steps {
                if case .string(let s)? = step.arguments["text"] { values.insert(s) }
                if let signals = step.verification?.signals {
                    for signal in signals {
                        if case .labelBecame(_, let to) = signal { values.insert(to) }
                    }
                }
                if let branch = step.branch {
                    collectFromCondition(branch.condition, into: &values)
                    visit(branch.thenSteps)
                    visit(branch.elseSteps)
                }
            }
        }
        func collectFromCondition(_ condition: IRCondition, into values: inout Set<String>) {
            switch condition {
            case .elementHasText(_, let equals): values.insert(equals)
            case .all(let cs), .any(let cs): for c in cs { collectFromCondition(c, into: &values) }
            case .not(let c): collectFromCondition(c, into: &values)
            default: break
            }
        }
        visit(steps)
        return values
    }

    /// Every `target.label`/`target.identifier`, and every `requiredElements`/`forbiddenElements` entry's
    /// `label`/`identifier`, anywhere in the document (including branch arms). Covers both an action step's
    /// own target and a `verifyOnly` step's target named only through its verification.
    static func allTargetLabels(in steps: [IRStep]) -> Set<String> {
        var labels: Set<String> = []
        for step in flattenSteps(steps) {
            if let target = step.target {
                if let l = target.label { labels.insert(l) }
                if let i = target.identifier { labels.insert(i) }
            }
            if let verification = step.verification {
                for el in verification.requiredElements + verification.forbiddenElements {
                    if let l = el.label { labels.insert(l) }
                    if let i = el.identifier { labels.insert(i) }
                }
            }
        }
        return labels
    }

    /// Every `target.within.label`/`target.within.identifier` anywhere in the document (including branch
    /// conditions' own targets, and nested branch arms).
    static func allTargetScopeLabels(in steps: [IRStep]) -> Set<String> {
        var labels: Set<String> = []
        func collect(_ target: IRTarget?) {
            guard let scope = target?.within else { return }
            if let l = scope.label { labels.insert(l) }
            if let i = scope.identifier { labels.insert(i) }
        }
        for step in flattenSteps(steps) {
            collect(step.target)
            if let branch = step.branch { collectFromCondition(branch.condition, into: &labels) }
        }
        return labels
    }

    private static func collectFromCondition(_ condition: IRCondition, into labels: inout Set<String>) {
        func addScope(_ target: IRTarget) {
            guard let scope = target.within else { return }
            if let l = scope.label { labels.insert(l) }
            if let i = scope.identifier { labels.insert(i) }
        }
        switch condition {
        case .elementExists(let t), .elementNotExists(let t), .elementEnabled(let t), .elementSelected(let t): addScope(t)
        case .elementHasText(let t, _): addScope(t)
        case .applicationStateIs: break
        case .all(let cs), .any(let cs): for c in cs { collectFromCondition(c, into: &labels) }
        case .not(let inner): collectFromCondition(inner, into: &labels)
        }
    }
}
