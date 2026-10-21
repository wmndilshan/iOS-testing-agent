import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("37. Failure Classification Tests")
struct FailureClassificationTests {
    let classifier = FailureClassifier()

    @Test("All fourteen required failure classes exist with their exact identifiers")
    func testRequiredClassesExist() {
        let required = ["OBSERVATION_FAILED", "ELEMENT_NOT_FOUND", "AMBIGUOUS_TARGET", "STALE_SNAPSHOT", "VALIDATION_FAILED",
                        "APP_STATE_MISMATCH", "XCTEST_FAILED", "VERIFICATION_FAILED", "APP_CRASHED", "SIMULATOR_UNAVAILABLE",
                        "APP_LAUNCH_FAILED", "APP_NOT_RESPONDING", "APPROVAL_EXPIRED", "RECOVERY_BUDGET_EXHAUSTED"]
        let actual = Set(FailureClass.allCases.map(\.rawValue))
        for r in required { #expect(actual.contains(r), "Missing failure class \(r)") }
    }

    @Test("Typed driver errors classify deterministically")
    func testDriverErrorMapping() {
        #expect(classifier.classify(DriverError.staleSnapshot(requested: "a", current: "b")) == .staleSnapshot)
        #expect(classifier.classify(DriverError.elementNotFound("x")) == .elementNotFound)
        #expect(classifier.classify(DriverError.ambiguousElement("x", count: 3)) == .ambiguousTarget)
        #expect(classifier.classify(DriverError.simulatorNotAvailable("udid")) == .simulatorUnavailable)
        #expect(classifier.classify(DriverError.elementNotHittable("x")) == .appStateMismatch)
        #expect(classifier.classify(DriverError.typeMismatch(expected: "button", actual: "image", elementID: "x")) == .appStateMismatch)
        #expect(classifier.classify(DriverError.observationFailed("no attachment")) == .observationFailed)
        #expect(classifier.classify(DriverError.actionFailed("XCUITest execution failed: xcodebuild test exited with status code 65.")) == .xctestFailed)
    }

    @Test("Text-only failures classify by known message shape")
    func testMessageShapes() {
        #expect(classifier.classifyMessage("Approval expired (120s TTL).") == .approvalExpired)
        #expect(classifier.classifyMessage("Action was denied by supervisor.") == .approvalDenied)
        #expect(classifier.classifyMessage("Application com.x crashed during the test") == .appCrashed)
        #expect(classifier.classifyMessage("Failed to launch com.x") == .appLaunchFailed)
        #expect(classifier.classifyMessage("Timed out while evaluating UI query") == .appNotResponding)
        #expect(classifier.classifyMessage("Unable to boot device") == .simulatorUnavailable)
        #expect(classifier.classifyMessage("Target element mismatch: Element 'e' role changed from 'button' to 'image'.") == .appStateMismatch)
        #expect(classifier.classifyMessage("Healing budget exhausted: 3 attempts exceeded limit of 2.") == .recoveryBudgetExhausted)
        #expect(classifier.classifyMessage("Fail-Closed Verification: step lacks an explicit verification rule") == .verificationFailed)
        #expect(classifier.classifyMessage("something nobody has seen before") == .unknown)
    }

    @Test("Classification is a pure function: same input, same output, every time")
    func testDeterminism() {
        let inputs = ["Approval expired (120s TTL).", "Stale snapshot!", "xcodebuild test exited with status code 65.", "???"]
        for input in inputs {
            let first = classifier.classifyMessage(input)
            for _ in 0..<20 { #expect(classifier.classifyMessage(input) == first) }
        }
    }

    @Test("Pipeline errors classify without consulting any model")
    func testPipelineErrorMapping() {
        #expect(classifier.classify(LLMProposalPipelineError.duplicateProposal(reason: "dup")) == .validationFailed)
        #expect(classifier.classify(approvalStatus: .expired) == .approvalExpired)
        #expect(classifier.classify(approvalStatus: .denied) == .approvalDenied)
        #expect(classifier.classify(approvalStatus: .approved) == nil)
    }

    @Test("Terminal-by-policy classes are exactly denial and hard budgets")
    func testTerminalByPolicy() {
        let terminal = Set(FailureClass.allCases.filter(\.isTerminalByPolicy))
        #expect(terminal == [.approvalDenied, .recoveryBudgetExhausted, .llmBudgetExhausted])
    }
}

