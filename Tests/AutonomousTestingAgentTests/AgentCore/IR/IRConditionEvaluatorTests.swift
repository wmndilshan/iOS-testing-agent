import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Pure unit tests for `IRConditionEvaluator` — no controller, no driver, no LLM. Every case is evaluated
/// directly against a hand-built `Observation`, exactly the "fresh trusted observation -> deterministic
/// condition evaluator -> THEN or ELSE" pipeline section 4 requires, isolated from execution plumbing.
@Suite("IR.4 Condition Evaluator")
struct IRConditionEvaluatorTests {

    static func obs(_ elements: [UIElementSnapshot], appState: AppState = .runningForeground) -> Observation {
        Observation(snapshotID: "snap_\(UUID().uuidString.prefix(6))", bundleID: "com.apple.mobilesafari", appState: appState, elements: elements)
    }

    @Test("elementExists: present -> satisfied, absent -> notSatisfied")
    func testElementExists() {
        let present = Self.obs([UIElementSnapshot(id: "e1", role: "button", label: "Test1")])
        let absent = Self.obs([])
        #expect(IRConditionEvaluator.evaluate(.elementExists(IRTarget(role: "button", label: "Test1")), in: present) == .satisfied)
        #expect(IRConditionEvaluator.evaluate(.elementExists(IRTarget(role: "button", label: "Test1")), in: absent) == .notSatisfied)
    }

    @Test("elementNotExists is the exact logical inverse of elementExists")
    func testElementNotExists() {
        let present = Self.obs([UIElementSnapshot(id: "e1", role: "button", label: "Test1")])
        let absent = Self.obs([])
        #expect(IRConditionEvaluator.evaluate(.elementNotExists(IRTarget(role: "button", label: "Test1")), in: present) == .notSatisfied)
        #expect(IRConditionEvaluator.evaluate(.elementNotExists(IRTarget(role: "button", label: "Test1")), in: absent) == .satisfied)
    }

    @Test("elementEnabled reflects the resolved element's isEnabled flag")
    func testElementEnabled() {
        let enabled = Self.obs([UIElementSnapshot(id: "e1", role: "button", label: "X", isEnabled: true)])
        let disabled = Self.obs([UIElementSnapshot(id: "e1", role: "button", label: "X", isEnabled: false)])
        #expect(IRConditionEvaluator.evaluate(.elementEnabled(IRTarget(role: "button", label: "X")), in: enabled) == .satisfied)
        #expect(IRConditionEvaluator.evaluate(.elementEnabled(IRTarget(role: "button", label: "X")), in: disabled) == .notSatisfied)
    }

    @Test("elementSelected reflects isSelected; unrecorded state is indeterminate, never guessed")
    func testElementSelected() {
        let selected = Self.obs([UIElementSnapshot(id: "e1", role: "button", label: "X", isSelected: true)])
        let notSelected = Self.obs([UIElementSnapshot(id: "e1", role: "button", label: "X", isSelected: false)])
        let unrecorded = Self.obs([UIElementSnapshot(id: "e1", role: "button", label: "X")])
        #expect(IRConditionEvaluator.evaluate(.elementSelected(IRTarget(role: "button", label: "X")), in: selected) == .satisfied)
        #expect(IRConditionEvaluator.evaluate(.elementSelected(IRTarget(role: "button", label: "X")), in: notSelected) == .notSatisfied)
        guard case .indeterminate = IRConditionEvaluator.evaluate(.elementSelected(IRTarget(role: "button", label: "X")), in: unrecorded) else {
            Issue.record("unrecorded selection state must be indeterminate"); return
        }
    }

    @Test("elementHasText compares the element's recorded value exactly")
    func testElementHasText() {
        let matching = Self.obs([UIElementSnapshot(id: "e1", role: "textField", identifier: "name", value: "Test1_E2E")])
        let different = Self.obs([UIElementSnapshot(id: "e1", role: "textField", identifier: "name", value: "Test1")])
        let cond = IRCondition.elementHasText(IRTarget(role: "textField", identifier: "name"), equals: "Test1_E2E")
        #expect(IRConditionEvaluator.evaluate(cond, in: matching) == .satisfied)
        #expect(IRConditionEvaluator.evaluate(cond, in: different) == .notSatisfied)
    }

    @Test("applicationStateIs compares the observation's own appState")
    func testApplicationStateIs() {
        let foreground = Self.obs([], appState: .runningForeground)
        let background = Self.obs([], appState: .runningBackground)
        #expect(IRConditionEvaluator.evaluate(.applicationStateIs(.runningForeground), in: foreground) == .satisfied)
        #expect(IRConditionEvaluator.evaluate(.applicationStateIs(.runningForeground), in: background) == .notSatisfied)
    }

    @Test("all requires every child to be satisfied; any requires at least one")
    func testAllAny() {
        let both = Self.obs([UIElementSnapshot(id: "a", role: "button", label: "A"), UIElementSnapshot(id: "b", role: "button", label: "B")])
        let onlyA = Self.obs([UIElementSnapshot(id: "a", role: "button", label: "A")])
        let neither = Self.obs([])
        let condA = IRCondition.elementExists(IRTarget(role: "button", label: "A"))
        let condB = IRCondition.elementExists(IRTarget(role: "button", label: "B"))

        #expect(IRConditionEvaluator.evaluate(.all([condA, condB]), in: both) == .satisfied)
        #expect(IRConditionEvaluator.evaluate(.all([condA, condB]), in: onlyA) == .notSatisfied)
        #expect(IRConditionEvaluator.evaluate(.any([condA, condB]), in: onlyA) == .satisfied)
        #expect(IRConditionEvaluator.evaluate(.any([condA, condB]), in: neither) == .notSatisfied)
    }

    @Test("not inverts satisfied/notSatisfied and preserves indeterminate")
    func testNot() {
        let present = Self.obs([UIElementSnapshot(id: "e1", role: "button", label: "X")])
        let absent = Self.obs([])
        let cond = IRCondition.elementExists(IRTarget(role: "button", label: "X"))
        #expect(IRConditionEvaluator.evaluate(.not(cond), in: present) == .notSatisfied)
        #expect(IRConditionEvaluator.evaluate(.not(cond), in: absent) == .satisfied)
    }

    @Test("an ambiguous locator match (2+ elements) is indeterminate, never guessed true or false")
    func testAmbiguousMatchIsIndeterminate() {
        let duplicated = Self.obs([UIElementSnapshot(id: "a", role: "button", label: "Dup"), UIElementSnapshot(id: "b", role: "button", label: "Dup")])
        guard case .indeterminate = IRConditionEvaluator.evaluate(.elementExists(IRTarget(role: "button", label: "Dup")), in: duplicated) else {
            Issue.record("an ambiguous match must be indeterminate"); return
        }
        guard case .indeterminate = IRConditionEvaluator.evaluate(.elementEnabled(IRTarget(role: "button", label: "Dup")), in: duplicated) else {
            Issue.record("elementEnabled over an ambiguous match must be indeterminate"); return
        }
    }

    @Test("an indeterminate child makes all/any/not indeterminate rather than silently false")
    func testIndeterminatePropagates() {
        let duplicated = Self.obs([UIElementSnapshot(id: "a", role: "button", label: "Dup"), UIElementSnapshot(id: "b", role: "button", label: "Dup")])
        let ambiguous = IRCondition.elementExists(IRTarget(role: "button", label: "Dup"))
        let alwaysTrue = IRCondition.applicationStateIs(.runningForeground)

        guard case .indeterminate = IRConditionEvaluator.evaluate(.all([alwaysTrue, ambiguous]), in: duplicated) else {
            Issue.record("all() with an indeterminate child must be indeterminate"); return
        }
        guard case .indeterminate = IRConditionEvaluator.evaluate(.any([.applicationStateIs(.runningBackground), ambiguous]), in: duplicated) else {
            Issue.record("any() with no satisfied child and an indeterminate child must be indeterminate, not notSatisfied"); return
        }
        guard case .indeterminate = IRConditionEvaluator.evaluate(.not(ambiguous), in: duplicated) else {
            Issue.record("not() over an indeterminate child must be indeterminate"); return
        }
    }

    // MARK: - Adversarial-IR contract, section 5A: scoped targets (IRTarget.within), resolved via real parentID ancestry

    /// Two "ALPHA" cells with the same role+label, distinguished only by which scrollView contains them —
    /// exactly the "ALPHA row inside the Collection items container" vs. some other container shape.
    static func scopedObservation() -> Observation {
        Self.obs([
            UIElementSnapshot(id: "collection_scroll", role: "scrollView", label: "Collection Items"),
            UIElementSnapshot(id: "search_scroll", role: "scrollView", label: "Search Results"),
            UIElementSnapshot(id: "alpha_in_collection", parentID: "collection_scroll", role: "cell", label: "ALPHA"),
            UIElementSnapshot(id: "alpha_in_search", parentID: "search_scroll", role: "cell", label: "ALPHA")
        ])
    }

    @Test("A scoped target (within) resolves uniquely to the descendant of the matching scope, ignoring an identically-labeled element under a different scope")
    func testScopedTargetResolvesToCorrectDescendant() {
        let target = IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView", label: "Collection Items"))
        #expect(IRConditionEvaluator.evaluate(.elementExists(target), in: Self.scopedObservation()) == .satisfied)
        // The OTHER scope's identically-labeled element must never be the one resolved.
        let otherScopeTarget = IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView", label: "Search Results"))
        #expect(IRConditionEvaluator.evaluate(.elementExists(otherScopeTarget), in: Self.scopedObservation()) == .satisfied, "resolves to the search-results ALPHA, a DIFFERENT element than the collection one")
    }

    @Test("Without a scope, the same target is genuinely ambiguous — proving the scope is what disambiguates, not something else")
    func testUnscopedIdenticalLabelsAreAmbiguous() {
        let unscoped = IRTarget(role: "cell", label: "ALPHA")
        guard case .indeterminate(let reason) = IRConditionEvaluator.evaluate(.elementExists(unscoped), in: Self.scopedObservation()) else {
            Issue.record("expected ambiguous/indeterminate without a scope"); return
        }
        #expect(reason.contains("matched 2 elements"))
    }

    @Test("A scope that itself doesn't resolve uniquely (absent or ambiguous) makes the whole scoped target indeterminate — never silently ignored")
    func testUnresolvableScopeMakesTargetIndeterminate() {
        let missingScope = IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView", label: "Nonexistent Container"))
        guard case .indeterminate = IRConditionEvaluator.evaluate(.elementExists(missingScope), in: Self.scopedObservation()) else {
            Issue.record("an unresolvable scope must make the target indeterminate, not fall back to unscoped matching"); return
        }

        let ambiguousScope = Self.obs([
            UIElementSnapshot(id: "s1", role: "scrollView", label: "Dup"),
            UIElementSnapshot(id: "s2", role: "scrollView", label: "Dup"),
            UIElementSnapshot(id: "e1", parentID: "s1", role: "cell", label: "ALPHA")
        ])
        let target = IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView", label: "Dup"))
        guard case .indeterminate = IRConditionEvaluator.evaluate(.elementExists(target), in: ambiguousScope) else {
            Issue.record("an ambiguous scope must make the target indeterminate"); return
        }
    }

    @Test("Scope resolution works through an intermediate wrapper element (grandchild, not just a direct child) — a real UI's row is rarely a direct child of its named container")
    func testScopeResolvesThroughIntermediateAncestor() {
        let observation = Self.obs([
            UIElementSnapshot(id: "collection_scroll", role: "scrollView", label: "Collection Items"),
            UIElementSnapshot(id: "row_wrapper", parentID: "collection_scroll", role: "other"),
            UIElementSnapshot(id: "alpha_cell", parentID: "row_wrapper", role: "cell", label: "ALPHA")
        ])
        let target = IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView", label: "Collection Items"))
        #expect(IRConditionEvaluator.evaluate(.elementExists(target), in: observation) == .satisfied)
    }

    @Test("An element outside the scope entirely (no ancestor relationship at all) never matches")
    func testElementOutsideScopeNeverMatches() {
        let observation = Self.obs([
            UIElementSnapshot(id: "collection_scroll", role: "scrollView", label: "Collection Items"),
            UIElementSnapshot(id: "unrelated_alpha", role: "cell", label: "ALPHA") // no parentID at all
        ])
        let target = IRTarget(role: "cell", label: "ALPHA", within: IRTargetScope(role: "scrollView", label: "Collection Items"))
        #expect(IRConditionEvaluator.evaluate(.elementExists(target), in: observation) == .notSatisfied)
    }
}
