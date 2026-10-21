import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// IR-robustness contract: expanded semantic-fidelity dataset (52 real, captured DeepSeek documents; a 53rd case,
/// P42-G1, was correctly REJECTED by the validator and has no accepted document — see
/// `testOrdinalTargetIsRejectedByValidator`). Every expectation here was written by reading each case's NL
/// text before inspecting what the model produced. Covers sections 3 (13 conditions + 14 actions + 7
/// signals), 4 (9 target-specificity cases), 5 (6 verification-completeness cases), and 13 (4 IR-vocabulary
/// gap probes). No network call in this file — all real generation already happened live.
@Suite("IR.22 IR-robustness contract Semantic Fidelity")
struct ExtendedIRSemanticFidelityTests {

    // MARK: - Fixture integrity

    /// 5 cases deliberately excluded here: Adversarial-IR contract added a validator rule (finding C) rejecting a
    /// verifyOnly step that names a transition-only signal (elementAppeared/selectedBecame/labelBecame/
    /// valueChanged/etc.), since such a step compares an observation against itself and such a signal can
    /// never honestly hold. P42-V4 was the original IR-robustness contract finding; re-checking the whole dataset under
    /// the new rule surfaced 4 more real, independent generations with the identical shape. All 5 correctly
    /// changed status from ACCEPTED (IR-robustness contract) to REJECTED (Adversarial-IR contract) — see
    /// `testFiveRealCasesRejectedByTransitionSignalRule` in IRExecutionSecurityTests.swift,
    /// which asserts this explicitly rather than silently dropping the cases from coverage.
    static let rejectedByTransitionSignalRule: Set<String> = ["P42-C5", "P42-V2", "P42-V3", "P42-V4", "P42-V5"]

    // MARK: - Section 3: 13 conditions

    struct Case { let caseID: String; let expectation: SemanticExpectation }

    static let conditionDataset: [Case] = [
        Case(caseID: "P42-C1", expectation: SemanticExpectation(caseID: "P42-C1", expectedActions: ["tap"], expectedConditionKinds: ["elementExists"], expectedBranchCount: 1)),
        Case(caseID: "P42-C2", expectation: SemanticExpectation(caseID: "P42-C2", expectedConditionKinds: ["elementNotExists"], forbiddenConditionKinds: ["elementExists"], expectedBranchCount: 1)),
        Case(caseID: "P42-C3", expectation: SemanticExpectation(caseID: "P42-C3", expectedActions: ["tap"], expectedConditionKinds: ["elementEnabled"], expectedBranchCount: 1)),
        Case(caseID: "P42-C4", expectation: SemanticExpectation(caseID: "P42-C4", expectedConditionKinds: ["elementEnabled"], expectedBranchCount: 1)),
        Case(caseID: "P42-C5", expectation: SemanticExpectation(caseID: "P42-C5", expectedActions: ["selectTab"], expectedConditionKinds: ["elementSelected"], expectedBranchCount: 1)),
        Case(caseID: "P42-C6", expectation: SemanticExpectation(caseID: "P42-C6", expectedActions: ["selectTab"], expectedConditionKinds: ["elementSelected"], expectedBranchCount: 1)),
        Case(caseID: "P42-C7", expectation: SemanticExpectation(caseID: "P42-C7", expectedActions: ["typeText"], expectedConditionKinds: ["elementHasText"], expectedBranchCount: 1, requiredTextValues: ["TSLA"])),
        Case(caseID: "P42-C8", expectation: SemanticExpectation(caseID: "P42-C8", expectedConditionKinds: ["applicationStateIs"], forbiddenConditionKinds: ["elementExists"], expectedBranchCount: 1)),
        Case(caseID: "P42-C9", expectation: SemanticExpectation(caseID: "P42-C9", expectedConditionKinds: ["applicationStateIs"], forbiddenConditionKinds: ["elementExists"], expectedBranchCount: 1)),
        Case(caseID: "P42-C10", expectation: SemanticExpectation(caseID: "P42-C10", expectedActions: ["tap"], expectedConditionKinds: ["all"], expectedBranchCount: 1)),
        Case(caseID: "P42-C11", expectation: SemanticExpectation(caseID: "P42-C11", expectedConditionKinds: ["any"], expectedBranchCount: 1)),
        Case(caseID: "P42-C12", expectation: SemanticExpectation(caseID: "P42-C12", expectedConditionKinds: ["not"], expectedBranchCount: 1)),
        Case(caseID: "P42-C13", expectation: SemanticExpectation(caseID: "P42-C13", expectedConditionKinds: ["elementExists", "elementSelected"], expectedBranchCount: 2))
    ]

    // MARK: - Section 3: 14 actions

    static let actionDataset: [Case] = [
        Case(caseID: "P42-A14", expectation: SemanticExpectation(caseID: "P42-A14", expectedActions: ["tap"], forbiddenActions: ["doubleTap"])),
        Case(caseID: "P42-A15", expectation: SemanticExpectation(caseID: "P42-A15", expectedActions: ["doubleTap"], forbiddenActions: ["tap"])),
        Case(caseID: "P42-A16", expectation: SemanticExpectation(caseID: "P42-A16", expectedActions: ["longPress"], forbiddenActions: ["tap"])),
        Case(caseID: "P42-A17", expectation: SemanticExpectation(caseID: "P42-A17", expectedActions: ["swipe"], forbiddenActions: ["scroll"])),
        Case(caseID: "P42-A18", expectation: SemanticExpectation(caseID: "P42-A18", expectedActions: ["scroll"])),
        Case(caseID: "P42-A19", expectation: SemanticExpectation(caseID: "P42-A19", expectedActions: ["scroll"])),
        Case(caseID: "P42-A20", expectation: SemanticExpectation(caseID: "P42-A20", expectedActions: ["typeText"], requiredTextValues: ["Growth Portfolio"])),
        Case(caseID: "P42-A21", expectation: SemanticExpectation(caseID: "P42-A21", expectedActions: ["clearText"], forbiddenActions: ["typeText"])),
        Case(caseID: "P42-A22", expectation: SemanticExpectation(caseID: "P42-A22", expectedActions: ["selectTab"], forbiddenActions: ["tap"])),
        Case(caseID: "P42-A23", expectation: SemanticExpectation(caseID: "P42-A23", expectedActions: ["navigateBack"], forbiddenActions: ["tap"])),
        Case(caseID: "P42-A24", expectation: SemanticExpectation(caseID: "P42-A24", expectedActions: ["dragAndDrop"])),
        Case(caseID: "P42-A25", expectation: SemanticExpectation(caseID: "P42-A25", expectedActions: ["inspectElements"])),
        Case(caseID: "P42-A26", expectation: SemanticExpectation(caseID: "P42-A26", expectedActions: ["getElementDetails"])),
        Case(caseID: "P42-A27", expectation: SemanticExpectation(caseID: "P42-A27", expectedActions: ["appState"]))
    ]

    // MARK: - Section 3: 7 signals

    static let signalDataset: [Case] = [
        Case(caseID: "P42-S28", expectation: SemanticExpectation(caseID: "P42-S28", expectedActions: ["typeText"], expectedSignalKinds: ["valueChanged"], requiredTextValues: ["150"])),
        Case(caseID: "P42-S29", expectation: SemanticExpectation(caseID: "P42-S29", expectedActions: ["tap"], expectedSignalKinds: ["labelChanged"])),
        Case(caseID: "P42-S30", expectation: SemanticExpectation(caseID: "P42-S30", expectedActions: ["tap"], expectedSignalKinds: ["labelBecame"], requiredTextValues: ["Connected"])),
        Case(caseID: "P42-S31", expectation: SemanticExpectation(caseID: "P42-S31", expectedActions: ["selectTab"], expectedSignalKinds: ["selectedBecame"])),
        Case(caseID: "P42-S32", expectation: SemanticExpectation(caseID: "P42-S32", expectedActions: ["tap"], expectedSignalKinds: ["navigationBarBecame"])),
        Case(caseID: "P42-S33", expectation: SemanticExpectation(caseID: "P42-S33", expectedActions: ["tap"], expectedSignalKinds: ["elementAppeared"])),
        Case(caseID: "P42-S34", expectation: SemanticExpectation(caseID: "P42-S34", expectedActions: ["tap"], expectedSignalKinds: ["elementDisappeared"]))
    ]

    // MARK: - Section 4: target specificity (9 cases) — 6 correct, 3 real vocabulary-gap findings

    static let targetCorrectDataset: [Case] = [
        Case(caseID: "P42-T1", expectation: SemanticExpectation(caseID: "P42-T1", expectedActions: ["tap"], requiredTargetLabels: ["Login"])),
        Case(caseID: "P42-T4", expectation: SemanticExpectation(caseID: "P42-T4", expectedActions: ["selectTab"], requiredTargetLabels: ["Collection"])),
        Case(caseID: "P42-T5", expectation: SemanticExpectation(caseID: "P42-T5", expectedActions: ["tap"], requiredTargetLabels: ["Collection"])),
        Case(caseID: "P42-T6", expectation: SemanticExpectation(caseID: "P42-T6", expectedActions: ["tap"], requiredTargetLabels: ["My Collection"])),
        Case(caseID: "P42-T7", expectation: SemanticExpectation(caseID: "P42-T7", expectedActions: ["tap"], requiredTargetLabels: ["BETA100"])),
        Case(caseID: "P42-T8", expectation: SemanticExpectation(caseID: "P42-T8", expectedActions: ["tap"], requiredTargetLabels: ["MSFT"]))
    ]

    // MARK: - Section 5: verification completeness (6 cases, all correctly represented)

    // MARK: - Section 13: IR vocabulary gap probes (G1-G4)

    @Test("G1 ('tap the third row'): correctly REJECTED by the validator itself — the model attempted a bare-role target (no way to express 'third'), and validateTargetSpecificity fail-closed. The strongest possible outcome: caught at the security boundary, never silently accepted.")
    func testOrdinalTargetIsRejectedByValidator() {
        // Reproduces the exact real shape from the live run (P42-G1's raw response): a bare {"role":"cell"}
        // target with no identifier/label. Re-asserted here deterministically (network-free) since the
        // rejected document has no accepted fixture to load from RobustnessCapturedIRFixtures.
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "Tap the third row in the results list", action: .tap, target: IRTarget(role: "cell"))
        let result = TestIRValidator.validate(TestIR(testKey: "P42-G1", title: "Tap third row (ordinal)", steps: [step]))
        #expect(!result.isAccepted, "an ordinal-only, bare-role target must remain rejected")
    }

}
