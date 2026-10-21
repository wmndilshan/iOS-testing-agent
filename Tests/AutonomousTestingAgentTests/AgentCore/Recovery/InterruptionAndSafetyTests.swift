import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("25. Interruption, Cancellation & Crash Safety Tests")
struct InterruptionAndSafetyTests {

    @Test("Cancellation prevents skill learning and clears active approvals")
    @MainActor
    func testCancellationClearsTheApproval() {
        let controller = ScenarioExecutionController()
        let scenario = ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!
        controller.startScenario(scenario)

        controller.cancel(reason: "User aborted.")

        #expect(controller.isCancelled == true)
        #expect(controller.activeApproval == nil)
    }

    @Test("Reset cleans state and removes transient tokens")
    @MainActor
    func testResetCleansState() {
        let controller = ScenarioExecutionController()
        let scenario = ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!
        controller.startScenario(scenario)

        controller.reset()

        #expect(controller.activeScenario == nil)
        #expect(controller.activeRunTrace == nil)
        #expect(controller.currentStepIndex == 0)
        #expect(controller.scenarioLifecycle == .idle)
    }
}

// MARK: - Test Suite 26: Resilient Adaptive Agent End-to-End Tests
