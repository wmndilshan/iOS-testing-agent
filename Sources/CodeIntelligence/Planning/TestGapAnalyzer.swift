import Foundation

/// A behavior a changed symbol should have a test for, implied by one of its traits.
public struct RequiredBehavior: Codable, Hashable, Sendable {
    public var id: String
    public var summary: String
    public var category: TestCategory
    public var trait: BehaviorTrait
    /// Words in a test's name that indicate it targets this behavior (lowercase prefixes).
    public var hints: [String]
    public var isFailurePath: Bool
    /// Needs a live simulator/device run (never part of `swift test`).
    public var liveRequired: Bool
}

public enum CoverageStatus: String, Codable, Sendable, Comparable {
    /// A test referencing the symbol shows evidence (name, `#expect(throws:)`) of targeting the behavior.
    case covered
    /// Tests reference the symbol but none shows evidence of this behavior. Needs a human/LLM look, not a new test by default.
    case unverified
    case missing
    public static func < (a: CoverageStatus, b: CoverageStatus) -> Bool {
        [.covered, .unverified, .missing].firstIndex(of: a)! < [.covered, .unverified, .missing].firstIndex(of: b)!
    }
}

public struct BehaviorCoverage: Codable, Hashable, Sendable {
    public var behavior: RequiredBehavior
    public var status: CoverageStatus
    public var evidence: [SymbolID]
}

public struct SymbolTestGap: Codable, Sendable {
    public var symbol: SymbolID
    public var change: SymbolChange
    public var traits: [TraitEvidence]
    public var behaviors: [BehaviorCoverage]
    /// Existing tests to extend first, most focused first.
    public var extendableTests: [SymbolID]
    /// Tests that reference the enclosing type only.
    public var typeLevelTests: [SymbolID]
    public var missing: [BehaviorCoverage] { behaviors.filter { $0.status == .missing } }
}

public struct CategorySelection: Codable, Sendable {
    public var selected: [TestCategory]
    /// Categories that applied but were not selected, with the reason (e.g. no UI test infrastructure).
    public var skipped: [String: String]
}

public enum TestGapAnalyzer {

    /// Heuristic obligations per trait. Deterministic; the LLM refines expectations, it does not choose the rules.
    public static func behaviors(for traits: [TraitEvidence], declaration d: Declaration, change: SymbolChange) -> [RequiredBehavior] {
        let body = d.body ?? BodyFacts()
        var out: [RequiredBehavior] = []
        func b(_ id: String, _ summary: String, _ c: TestCategory, _ t: BehaviorTrait, _ hints: [String], failure: Bool = false, live: Bool = false) {
            out.append(RequiredBehavior(id: id, summary: summary, category: c, trait: t, hints: hints, isFailurePath: failure, liveRequired: live))
        }
        let set = Set(traits.map(\.trait))
        for t in set.sorted() {
            switch t {
            case .pureLogic:
                b("representative", "representative inputs produce the expected result", .unit, t, ["return", "produce", "compute", "map", "result", "valid"])
            case .throwing:
                b("success", "succeeds without throwing for valid input", .unit, t, ["succe", "valid", "accept", "happy", "complet", "pass"])
                b("expected-failure", "throws \(d.typedThrows ?? body.thrownTypes.filter { $0 != "." }.first ?? "the documented error") for invalid input",
                  .negative, t, ["throw", "fail", "error", "invalid", "reject", "refus", "denied", "missing"], failure: true)
            case .async:
                b("async-success", "completes with the expected result when awaited", .unit, t, ["succe", "complet", "return", "await"])
                if body.loopCount > 0 || body.awaitCount > 1 || !body.concurrencyConstructs.isEmpty {
                    b("cancellation", "stops cleanly and leaves consistent state when the task is cancelled", .concurrency, t, ["cancel"])
                }
            case .concurrency:
                b("serialization", "concurrent calls are serialized and leave state consistent", .concurrency, t, ["concurren", "serial", "parallel", "race", "simultan", "reentr", "overlap"])
                if body.concurrencyConstructs.contains(where: { $0.hasPrefix("Task") || $0.contains("Group") || $0 == "addTask" }) {
                    b("task-cancellation", "spawned tasks are cancelled or awaited; none outlive the operation", .concurrency, t, ["cancel", "leak", "outliv"])
                }
                if !body.assignedMembers.isEmpty, body.awaitCount > 0 {
                    b("suspension-state", "state read before a suspension point is re-validated after it", .concurrency, t, ["stale", "reentr", "interleav", "race"])
                }
            case .stateMachine:
                b("valid-transitions", "every valid transition reaches the expected next state", .stateMachine, t, ["transition", "advance", "sequence", "complet", "lifecycle", "phase"])
                b("invalid-transitions", "invalid transitions are rejected and leave the state unchanged", .stateMachine, t, ["illegal", "invalid", "reject", "refus", "cannot", "not allowed", "disallow"], failure: true)
            case .validation:
                b("valid-input", "valid input is accepted", .unit, t, ["valid", "accept", "allow", "pass"])
                b("invalid-input", "invalid input is rejected with the specific reason", .negative, t, ["invalid", "reject", "refus", "denied", "fail"], failure: true)
                b("boundary", "values at the limits (empty, max, min, off-by-one) are classified correctly", .boundary, t, ["bound", "limit", "max", "min", "empty", "edge", "exact"])
            case .parsing:
                b("parse-valid", "well-formed input parses to the expected value", .unit, t, ["pars", "decod", "valid"])
                b("parse-malformed", "malformed input fails without partial results", .negative, t, ["malform", "invalid", "corrupt", "garbage", "bad"], failure: true)
                b("parse-empty", "empty input is handled explicitly", .boundary, t, ["empty", "blank", "nil"])
                b("parse-boundary", "boundary input (very long, unicode, nested) parses correctly", .boundary, t, ["bound", "long", "unicode", "nest", "large", "edge"])
            case .persistence:
                b("round-trip", "written data reads back identically", .persistence, t, ["round", "persist", "save", "load", "write", "read", "store"])
                b("reopen", "data survives closing and reopening the store", .persistence, t, ["reopen", "restart", "reload", "relaunch", "survive", "new instance"])
                b("atomic-failure", "a failed or interrupted write leaves the previous data intact", .persistence, t, ["atomic", "corrupt", "partial", "interrupt", "fail"], failure: true)
            case .dataMigration:
                b("schema-version", "older schema versions decode or migrate; unknown newer versions fail closed", .persistence, t, ["version", "schema", "migrat", "older", "legacy"])
            case .retryPolicy:
                b("retryable", "retryable failures are retried", .unit, t, ["retry", "retries"])
                b("non-retryable", "non-retryable failures are not retried", .negative, t, ["nonretry", "non-retry", "terminal", "no retry", "noautoretry", "not retr"], failure: true)
                b("attempt-limit", "retrying stops at the attempt limit", .boundary, t, ["limit", "max", "exhaust", "attempt", "budget"])
            case .authorization:
                b("auth-valid", "a valid authorization is accepted exactly for its scope", .security, t, ["authoriz", "approv", "grant", "valid"])
                b("auth-expired", "an expired authorization is rejected", .security, t, ["expir", "ttl", "timeout"], failure: true)
                b("auth-stale", "an authorization for stale state is rejected", .security, t, ["stale", "toctou", "outdated", "changed"], failure: true)
                b("auth-denied", "a denied or missing authorization never reaches the effect", .security, t, ["deni", "without", "unapprov", "reject", "never"], failure: true)
                b("auth-replay", "a consumed authorization cannot be replayed", .security, t, ["replay", "consum", "reuse", "twice", "single-use"], failure: true)
            case .security:
                b("security-invariant", "the security invariant holds for hostile input (fail closed)", .security, t, ["secur", "redact", "secret", "fail closed", "hostile", "inject", "untrusted"], failure: true)
            case .idMapping:
                b("id-correct", "each ID maps to the correct entity", .unit, t, ["map", "correlat", "resolv", "match"])
                b("id-mismatch", "a mismatched ID is detected and rejected", .negative, t, ["mismatch", "wrong", "differ"], failure: true)
                b("id-unknown", "an unknown ID fails explicitly", .negative, t, ["unknown", "missing", "notfound", "not found"], failure: true)
            case .uiStateMapping:
                b("ui-states", "each model state maps to the expected presentation state", .unit, t, ["state", "present", "display", "show", "map"])
                b("ui-stale-error", "stale and error states are presented as such, never as success", .negative, t, ["stale", "error", "fail"], failure: true)
            case .swiftUIView:
                b("view-render", "the view renders its states", .snapshot, t, ["render", "snapshot", "view"])
            case .recovery:
                b("recovery-restart", "after a restart the operation recovers to a consistent state", .integration, t, ["restart", "recover", "resum", "crash"])
                b("recovery-unknown-outcome", "an operation with unknown outcome is not blindly re-executed", .negative, t, ["unknown", "never", "not re", "require", "blind"], failure: true)
            case .workflowOrchestration:
                b("orchestration-path", "the orchestrated path runs end to end with fakes at the boundaries", .integration, t, ["integrat", "end", "workflow", "flow", "path", "schedul"])
            case .deviceInteraction:
                b("device-mocked", "device interaction is exercised through the mock driver", .integration, t, ["mock", "driver", "simulat"])
                b("device-live", "behavior verified against a live simulator (manual CLI run)", .endToEnd, t, ["live"], live: true)
            case .externalSideEffects:
                b("side-effect-isolated", "the side effect happens exactly once, through an injected boundary", .integration, t, ["once", "side", "effect", "invok", "call"])
            case .publicAPI:
                b("api-contract", "existing callers' expectations of the changed public signature still hold", .contract, t, ["contract", "api", "public", "compat"])
            case .protocolContract:
                b("protocol-contract", "every conforming type satisfies the protocol's contract", .contract, t, ["contract", "conform", "protocol"])
            case .failureHandling:
                b("failure-path", "failures are handled and reported, not swallowed", .negative, t, ["fail", "error", "catch", "fallback"], failure: true)
            case .boundaryCrossing:
                b("architecture-boundary", "the new dependency respects the layer and process-launch rules", .architecture, t, ["architect", "layer", "boundar", "depend"])
            }
        }
        // Each added or changed branch condition is a behavior no existing test can have been written for.
        for (n, condition) in change.addedBranches.prefix(5).enumerated() {
            let isGuard = condition.hasPrefix("guard ")
            let isCatch = condition.hasPrefix("catch ")
            b("branch-\(n + 1)", "the new condition `\(condition)` is exercised on both outcomes", isGuard || isCatch ? .negative : .unit,
              .failureHandling, [], failure: isGuard || isCatch)
        }
        if change.kind == .modified, !Set(change.aspects).isDisjoint(with: [.controlFlow, .errorHandling, .stateMutation]) {
            b("regression", "behavior for inputs that worked before the change is unchanged", .regression, .pureLogic, ["regress", "unchanged", "still", "preserv"])
        }
        return out
    }

    public static func analyze(_ changes: ChangeSet, index: ASTIndex, tests: TestIndex) -> [SymbolTestGap] {
        let changedTests = Set(changes.symbols.filter { $0.role == .test && $0.kind != .removed }.map(\.symbol))
        return changes.productionSymbols.compactMap { change -> SymbolTestGap? in
            guard change.kind != .removed, let d = index[change.symbol], d.kind.isCallable || d.kind == .property || d.kind.isType else { return nil }
            // Stored properties without logic and type headers without conformance changes carry no behavior of their own.
            if d.kind == .property, d.body == nil || (d.body?.branchCount == 0 && d.body?.references.count ?? 0 <= 1 && d.body?.concurrencyConstructs.isEmpty ?? true) { return nil }
            if d.kind.isType, !change.aspects.contains(.conformance) { return nil }
            let traits = TraitDetector.detect(d, change: change, index: index)
            let covering = tests.tests(covering: d.id)
            let behaviors = behaviors(for: traits, declaration: d, change: change).map { coverage($0, covering, changedTests: changedTests) }
            let extendable = rankExtendable(covering, for: d).map(\.id)
            let typeLevel = d.container.map { tests.tests(exercisingType: $0).map(\.id).filter { !extendable.contains($0) } } ?? []
            return SymbolTestGap(symbol: d.id, change: change, traits: traits, behaviors: behaviors, extendableTests: Array(extendable.prefix(5)), typeLevelTests: Array(typeLevel.prefix(5)))
        }
    }

    /// Tests to extend, best first: suites/files named after the changed type (`DispatchAuthorizerTests`), then the most
    /// focused (fewest production symbols referenced), then by ID.
    static func rankExtendable(_ tests: [TestCaseFacts], for d: Declaration) -> [TestCaseFacts] {
        let owner = d.container.map(SymbolGraph.simpleName) ?? d.name
        func affinity(_ t: TestCaseFacts) -> Int {
            let suite = t.suite.map(SymbolGraph.simpleName) ?? ""
            let file = (t.span.file as NSString).lastPathComponent
            if suite == owner + "Tests" || file == owner + "Tests.swift" { return 0 }
            if suite.hasPrefix(owner) || file.hasPrefix(owner) { return 1 }
            return 2
        }
        return tests.sorted { (affinity($0), $0.referencedSymbols.count, $0.id) < (affinity($1), $1.referencedSymbols.count, $1.id) }
    }

    /// Evidence is a hint that starts one of the words of the test's own name or display name (the suite name is not
    /// evidence for each of its tests), or `#expect(throws:)` for a throwing failure path. Branch behaviors have no
    /// name hints: they are new, so only a test changed in the same change set can plausibly cover them.
    static func coverage(_ behavior: RequiredBehavior, _ tests: [TestCaseFacts], changedTests: Set<SymbolID> = []) -> BehaviorCoverage {
        guard !tests.isEmpty else { return BehaviorCoverage(behavior: behavior, status: .missing, evidence: []) }
        if behavior.id.hasPrefix("branch-") {
            let touched = tests.filter { changedTests.contains($0.id) }.map(\.id).sorted()
            return BehaviorCoverage(behavior: behavior, status: touched.isEmpty ? .missing : .unverified, evidence: touched)
        }
        let matching = tests.filter { t in
            let words = TraitDetector.tokens(t.name) + TraitDetector.tokens(t.displayName ?? "")
            let phrase = words.joined(separator: " ")
            let matched = behavior.hints.contains { hint in
                let h = hint.replacingOccurrences(of: "-", with: " ")
                return h.contains(" ") ? phrase.contains(h) : words.contains { $0.hasPrefix(h) }
            }
            if matched { return true }
            if behavior.trait == .throwing, behavior.isFailurePath, t.expectsThrow { return true }
            return false
        }
        return BehaviorCoverage(behavior: behavior, status: matching.isEmpty ? .unverified : .covered, evidence: matching.map(\.id).sorted())
    }

    /// Categories to generate: those of missing behaviors, minus categories without infrastructure.
    public static func selectCategories(_ gaps: [SymbolTestGap], conventions: TestConventions) -> CategorySelection {
        var selected = Set<TestCategory>()
        var skipped: [String: String] = [:]
        let hasUITests = conventions.frameworkCounts[TestFramework.xcuitest.rawValue, default: 0] > 0
        for gap in gaps {
            for c in gap.behaviors where c.status == .missing {
                let category = c.behavior.category
                switch category {
                case .snapshot:
                    skipped[category.rawValue] = "no snapshot-testing library in the test targets"
                case .ui where !hasUITests:
                    skipped[category.rawValue] = "no UI test target"
                case .endToEnd:
                    skipped[category.rawValue] = "live simulator runs are manual CLI runs, not generated tests (planned as live-required specs only)"
                case .performance:
                    skipped[category.rawValue] = "performance tests are only planned when a skill requires them"
                default:
                    selected.insert(category)
                }
            }
        }
        return CategorySelection(selected: selected.sorted(), skipped: skipped)
    }
}
