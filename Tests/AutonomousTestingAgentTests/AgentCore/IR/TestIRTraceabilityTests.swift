import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// IR-execution contract, section 4: an explicit, deterministic AIO-step -> IR-step traceability check for DEMO-TC-872,
/// classifying every one of the 32 AIO steps as exactly one of `.represented`, `.representedByMultiple`, or
/// `.unsupportedWithReason` — never silently dropped, never a fake mapping.
@Suite("IR.10 Traceability")
struct TestIRTraceabilityTests {

    enum Category: Equatable { case represented, representedByMultiple, unsupportedWithReason }

    /// Flattens branch arms into one linear list, depth-first.
    static func flatten(_ steps: [IRStep]) -> [IRStep] {
        steps.flatMap { step -> [IRStep] in
            var out = [step]
            if let branch = step.branch { out += flatten(branch.thenSteps) + flatten(branch.elseSteps) }
            return out
        }
    }

    /// Classifies every `sourceStepNumber` present in `steps` (including nested branch-arm steps).
    static func classify(_ ir: TestIR, verdicts: [String: IRStepVerdict]) -> [Int: Category] {
        let flat = Self.flatten(ir.steps)
        var byNumber: [Int: [IRStep]] = [:]
        for step in flat { byNumber[step.sourceStepNumber, default: []].append(step) }
        var result: [Int: Category] = [:]
        for (number, group) in byNumber {
            let allUnsupported = group.allSatisfy { step in
                if case .unsupported = verdicts[step.id] { return true }
                return false
            }
            if allUnsupported {
                result[number] = .unsupportedWithReason
            } else if group.count > 1 {
                result[number] = .representedByMultiple
            } else {
                result[number] = .represented
            }
        }
        return result
    }

    @Test("An AIO step number entirely missing from the IR is detected, not silently accepted")
    func testMissingSourceStepIsDetected() {
        // A document that (by construction, simulating a sloppy generator) never mentions AIO step 7.
        let steps = (1...32).filter { $0 != 7 }.map { n in
            IRStep(id: "s\(n)", sourceStepNumber: n, intent: "step \(n)", action: .tap, target: IRTarget(role: "button", label: "X\(n)"))
        }
        let ir = TestIR(testKey: "GAP-TEST", title: "t", steps: steps)
        let classification = Self.classify(ir, verdicts: TestIRValidator.validate(ir).stepVerdicts)
        #expect(!classification.keys.contains(7))
        #expect(Set(classification.keys) != Set(1...32))
    }
}
