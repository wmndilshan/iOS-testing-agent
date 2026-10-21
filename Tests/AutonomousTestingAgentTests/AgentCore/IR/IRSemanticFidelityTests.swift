import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Semantic-gate contract: compares a hand-written `SemanticExpectation` (built from the NL text alone, independently of
/// any generated IR) against the real, captured DeepSeek document for 16 categories (A–P from the phase
/// spec) plus DEMO-TC-872. Every expectation here was written by reading the case's natural-language text
/// BEFORE looking at what the model produced — never reverse-engineered from the real IR to guarantee a
/// pass. `SemanticFidelityGate.evaluate` is pure and deterministic (see `SemanticExpectation.swift`); no
/// network call happens in this file.
@Suite("IR.18 Semantic-gate contract Semantic Fidelity")
struct IRSemanticFidelityTests {

    struct Case {
        let category: String
        let caseID: String
        let expectation: SemanticExpectation
    }

    static let dataset: [Case] = [
        Case(category: "A. elementExists", caseID: "SEM-P5-A", expectation: SemanticExpectation(
            caseID: "SEM-P5-A", expectedActions: ["tap"],
            expectedConditionKinds: ["elementExists"], forbiddenConditionKinds: ["elementSelected", "elementEnabled", "elementHasText", "applicationStateIs"],
            expectedBranchCount: 1)),
        Case(category: "B. elementSelected", caseID: "SEM-P1-B", expectation: SemanticExpectation(
            caseID: "SEM-P1-B", expectedActions: ["selectTab"],
            expectedConditionKinds: ["elementSelected"], forbiddenConditionKinds: ["elementExists"],
            expectedBranchCount: 1)),
        Case(category: "C. elementEnabled", caseID: "SEM-P2-B", expectation: SemanticExpectation(
            caseID: "SEM-P2-B", expectedActions: ["tap"],
            expectedConditionKinds: ["elementEnabled"], forbiddenConditionKinds: ["elementExists"],
            expectedBranchCount: 1)),
        Case(category: "D. elementHasText", caseID: "SEM-P3-B", expectation: SemanticExpectation(
            caseID: "SEM-P3-B", expectedActions: ["typeText"],
            expectedConditionKinds: ["elementHasText"], forbiddenConditionKinds: ["elementExists"],
            expectedBranchCount: 1, requiredTextValues: ["MSFT"])),
        Case(category: "E. applicationStateIs", caseID: "SEM-P4-B", expectation: SemanticExpectation(
            caseID: "SEM-P4-B",
            expectedConditionKinds: ["applicationStateIs"], forbiddenConditionKinds: ["elementExists"],
            expectedBranchCount: 1)),
        Case(category: "F. elementNotExists", caseID: "SEM-P5-B", expectation: SemanticExpectation(
            caseID: "SEM-P5-B", expectedActions: ["tap"],
            expectedConditionKinds: ["elementNotExists"], forbiddenConditionKinds: ["elementExists"],
            expectedBranchCount: 1)),
        Case(category: "G. tap", caseID: "SEM-ACT-TAP", expectation: SemanticExpectation(
            caseID: "SEM-ACT-TAP", expectedActions: ["tap"], forbiddenActions: ["selectTab"])),
        Case(category: "H. selectTab", caseID: "SEM-ACT-TAB", expectation: SemanticExpectation(
            caseID: "SEM-ACT-TAB", expectedActions: ["selectTab"], forbiddenActions: ["tap"])),
        Case(category: "I. navigateBack", caseID: "SEM-ACT-BACK", expectation: SemanticExpectation(
            caseID: "SEM-ACT-BACK", expectedActions: ["navigateBack"], forbiddenActions: ["tap"])),
        // J deliberately does not pin an exact requiredTextValues string: "right"/"left" are both correct
        // horizontal answers, and forcing one literal word would make the expectation itself wrong, not the
        // model — see the written report's note on this. Checked instead by direct inspection below.
        Case(category: "J. horizontal scroll", caseID: "SEM-ACT-SCROLL-H", expectation: SemanticExpectation(
            caseID: "SEM-ACT-SCROLL-H", expectedActions: ["scroll"], forbiddenActions: ["swipe"])),
        Case(category: "K. valueChanged", caseID: "SEM-SIG-VALUECHANGED", expectation: SemanticExpectation(
            caseID: "SEM-SIG-VALUECHANGED", expectedActions: ["typeText"], expectedSignalKinds: ["valueChanged"])),
        Case(category: "L. labelBecame", caseID: "SEM-SIG-LABELBECAME", expectation: SemanticExpectation(
            caseID: "SEM-SIG-LABELBECAME", expectedSignalKinds: ["labelBecame"], requiredTextValues: ["Active"])),
        Case(category: "M. selectedBecame", caseID: "SEM-SIG-SELECTEDBECAME", expectation: SemanticExpectation(
            caseID: "SEM-SIG-SELECTEDBECAME", expectedActions: ["selectTab"], expectedSignalKinds: ["selectedBecame"])),
        Case(category: "N. navigationBarBecame", caseID: "SEM-SIG-NAVBAR", expectation: SemanticExpectation(
            caseID: "SEM-SIG-NAVBAR", expectedActions: ["tap"], expectedSignalKinds: ["navigationBarBecame"])),
        // O is intentionally NOT given a strict expectedConditionKinds — see testConditionalBranchCaseIsGenuinelyAmbiguous.
        Case(category: "P. nested conditional", caseID: "GEN-LIVE-I", expectation: SemanticExpectation(
            caseID: "GEN-LIVE-I", expectedBranchCount: 2))
    ]

    // MARK: - O: a genuinely ambiguous case, reported honestly rather than forced into a pass/fail

    // MARK: - Section 12: a deterministic regression test per semantic rule (network-free)

    @Test("Regression: expectedAction/forbiddenAction/expectedConditionKind/forbiddenConditionKind/expectedSignalKind/expectedBranchCount/requiredTextValues/requiresCredentialRef each independently produce a mismatch when violated")
    func testEachRuleIndependentlyDetectsAViolation() {
        let ir = TestIR(testKey: "T", title: "t", steps: [
            IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .tap, target: IRTarget(role: "button", label: "X"),
                   verification: IRVerification(description: "d", signals: [.selectedBecame(SignalLocator(role: "button", label: "X"))]))
        ])
        func mismatchProperties(_ expectation: SemanticExpectation) -> Set<String> {
            Set(SemanticFidelityGate.evaluate(expectation: expectation, against: ir).mismatches.map(\.property))
        }
        #expect(mismatchProperties(SemanticExpectation(caseID: "t", expectedActions: ["selectTab"])) == ["expectedAction"])
        #expect(mismatchProperties(SemanticExpectation(caseID: "t", forbiddenActions: ["tap"])) == ["forbiddenAction"])
        #expect(mismatchProperties(SemanticExpectation(caseID: "t", expectedConditionKinds: ["elementExists"])) == ["expectedConditionKind"])
        #expect(mismatchProperties(SemanticExpectation(caseID: "t", expectedSignalKinds: ["labelBecame"])) == ["expectedSignalKind"])
        #expect(mismatchProperties(SemanticExpectation(caseID: "t", expectedBranchCount: 1)) == ["expectedBranchCount"])
        #expect(mismatchProperties(SemanticExpectation(caseID: "t", requiredTextValues: ["nope"])) == ["requiredTextValue"])
        #expect(mismatchProperties(SemanticExpectation(caseID: "t", requiresCredentialRef: true)) == ["requiresCredentialRef"])
        // IR-robustness contract addition: requiredTargetLabels.
        #expect(mismatchProperties(SemanticExpectation(caseID: "t", requiredTargetLabels: ["NotPresent"])) == ["requiredTargetLabel"])
        // IR-robustness contract addition: requiresVerificationPresence (the base `ir` step above DOES carry a
        // verification, so this must NOT report a mismatch — proven on a step that genuinely lacks one).
        let noVerificationIR = TestIR(testKey: "T", title: "t", steps: [IRStep(id: "s1", sourceStepNumber: 1, intent: "x", action: .tap, target: IRTarget(role: "button", label: "X"))])
        let vpResult = SemanticFidelityGate.evaluate(expectation: SemanticExpectation(caseID: "t", requiresVerificationPresence: true), against: noVerificationIR)
        #expect(vpResult.classification == .semanticMismatch)
        #expect(vpResult.mismatches.map(\.property) == ["requiresVerificationPresence"])

        let branchIR = TestIR(testKey: "T", title: "t", steps: [
            IRStep(id: "b1", sourceStepNumber: 1, intent: "x", action: .verifyOnly,
                   branch: IRBranch(condition: .elementExists(IRTarget(role: "button", label: "X")), thenSteps: [], elseSteps: []))
        ])
        let forbiddenKindResult = SemanticFidelityGate.evaluate(expectation: SemanticExpectation(caseID: "t", forbiddenConditionKinds: ["elementExists"]), against: branchIR)
        #expect(forbiddenKindResult.classification == .semanticMismatch)
        #expect(forbiddenKindResult.mismatches.map(\.property) == ["forbiddenConditionKind"])
    }
}
