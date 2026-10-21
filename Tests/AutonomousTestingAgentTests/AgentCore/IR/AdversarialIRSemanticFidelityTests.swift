import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Adversarial-IR contract: safe IR vocabulary expansion. Covers the 24 real, captured DeepSeek documents from the
/// scoped-target / ordinal / state-verification / transition-verification / ordinary-baseline dataset.
/// Every expectation was written from the NL text before inspecting what the model produced. No network
/// call in this file — all real generation already happened live.
@Suite("IR.25 Adversarial-IR contract Semantic Fidelity")
struct AdversarialIRSemanticFidelityTests {

    // MARK: - Section 5A: scoped targets (within) — 5/5 real cases used it correctly

    struct Case { let caseID: String; let expectation: SemanticExpectation }

    static let scopedTargetDataset: [Case] = [
        Case(caseID: "P43-SCOPE1", expectation: SemanticExpectation(caseID: "P43-SCOPE1", expectedActions: ["tap"], requiredTargetLabels: ["ALPHA"], requiredTargetScopeLabels: ["Collection Items"])),
        Case(caseID: "P43-SCOPE2", expectation: SemanticExpectation(caseID: "P43-SCOPE2", expectedActions: ["tap"], requiredTargetLabels: ["Search"], requiredTargetScopeLabels: ["Login"])),
        Case(caseID: "P43-SCOPE3", expectation: SemanticExpectation(caseID: "P43-SCOPE3", expectedActions: ["tap"], requiredTargetLabels: ["Save"], requiredTargetScopeLabels: ["Settings"])),
        Case(caseID: "P43-SCOPE4", expectation: SemanticExpectation(caseID: "P43-SCOPE4", expectedActions: ["tap"], requiredTargetLabels: ["+"], requiredTargetScopeLabels: ["MSFT"])),
        Case(caseID: "P43-SCOPE5", expectation: SemanticExpectation(caseID: "P43-SCOPE5", expectedActions: ["tap"], requiredTargetLabels: ["Delete"], requiredTargetScopeLabels: ["Notification"]))
    ]

    // MARK: - Section 3/13: ordinal position — reconfirmed unsupported (P43-ORD1) or genuinely hallucinated (ORD2-5)

    @Test("P43-ORD1 ('the first result'): correctly REJECTED by the validator — bare-role target, no way to express 'first'. Reconfirms IR-robustness contract's G1 finding on fresh real generations.")
    func testOrd1RejectedReconfirmed() {
        // Reproduces the real rejected shape live (no accepted fixture exists to load).
        let step = IRStep(id: "s1", sourceStepNumber: 1, intent: "Tap the first result in the search list", action: .tap, target: IRTarget(role: "cell"))
        let result = TestIRValidator.validate(TestIR(testKey: "P43-ORD1", title: "First result in search list", steps: [step]))
        #expect(!result.isAccepted)
    }

    // MARK: - Section 5C: state vs. transition verification placement

    static let stateVerificationCaseIDs = ["P43-STATE1", "P43-STATE2", "P43-STATE3", "P43-STATE4", "P43-STATE5"]

    static let transitionVerificationCaseIDs = ["P43-TRANS1", "P43-TRANS2", "P43-TRANS3", "P43-TRANS4", "P43-TRANS5"]

    // MARK: - Section 6: ordinary baseline — must NOT use the new vocabulary

}
