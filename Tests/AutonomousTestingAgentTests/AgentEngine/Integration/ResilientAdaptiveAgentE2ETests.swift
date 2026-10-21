import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("26. Resilient Adaptive Agent End-to-End Tests")
struct ResilientAdaptiveAgentE2ETests {

    @Test("Run trace records full lifecycle events without leaking secrets")
    func testEndToEndRunTraceRecordsCompleteLifecycle() {
        var trace = RunTrace(runID: "RUN_A1", scenarioID: "SCENARIO-LANG-SHEET")
        trace.append(eventType: .observed, snapshotID: "snap_0", result: "38 elements observed")
        trace.append(eventType: .skillLookup, result: "Querying skills for SCENARIO-LANG-SHEET")
        trace.append(eventType: .skillSelected, skillID: "open-language-sheet", skillVersion: 1, result: "Selected v1")
        // The redaction regex matches Google API-key-shaped strings: "AIza" + exactly 35
        // alphanumeric/underscore/hyphen characters (39 chars total, matching real key length).
        let dummyAPIKey = "AIzaSyDummyTestKey1234567890ABCDEFGHIJK"
        #expect(dummyAPIKey.count == 39, "Test fixture must match the real Google API key shape for the redaction regex to fire.")
        trace.append(eventType: .stepExecuted, stepID: "step_0", result: "Tapped button with apiKey \(dummyAPIKey)")
        trace.append(eventType: .verificationPassed, result: "Sheet presented")

        #expect(trace.events.count == 5)
        #expect(trace.events[0].eventType == .observed)
        #expect(trace.events[2].eventType == .skillSelected)
        // Redaction verification
        let stepEvent = trace.events[3]
        #expect(!stepEvent.result.contains(dummyAPIKey))
        #expect(stepEvent.result.contains("[REDACTED_API_KEY]"))
    }

}
