import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Interruption classification")
struct InterruptionClassificationTests {
    @Test("Approval timeout, xcodebuild interruption, simulator loss and app crash are classified distinctly")
    func testInterruptionClassification() {
        let c = FailureClassifier()
        #expect(c.classifyMessage("Approval expired (120s TTL).") == .approvalExpired)
        #expect(c.classifyMessage("xcodebuild test exited with status code 137") == .xctestFailed)
        #expect(c.classify(DriverError.simulatorNotAvailable("udid")) == .simulatorUnavailable)
        #expect(c.classifyMessage("Application com.x crashed") == .appCrashed)
    }
}
