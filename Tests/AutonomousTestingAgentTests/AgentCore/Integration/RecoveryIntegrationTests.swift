import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("40. Recovery Integration Tests")
@MainActor
struct RecoveryIntegrationTests {

    @Test("A failed XCTest dispatch is classified and a recovery decision recorded, without re-dispatching")
    func testDispatchFailureClassifiedNoAutoRetry() async throws {
        let h = RunHarness()
        h.begin()
        let s0 = ProductFixtures.observation("f0", [ProductFixtures.dropdown])
        h.controller.recordObservation(s0)
        let proposal = ActionProposal(scenarioID: h.scenario.id, snapshotID: s0.snapshotID, elementID: "elem_29", expectedRole: "button",
                                      expectedIdentifier: "change-language-dropdown-button", toolName: "tap_element", reason: "r")
        _ = h.controller.handleProposal(proposal)
        h.controller.approveCurrentStep(source: .testAuthority)
        await h.driver.setShouldThrowError(.actionFailed("XCUITest execution failed: xcodebuild test exited with status code 65."))
        let result = await h.controller.dispatchCurrentStep(driver: h.driver, toolRegistry: h.registry)
        if case .success = result { Issue.record("dispatch should fail") }

        #expect(h.controller.lastFailureClass == .xctestFailed)
        let decision = try #require(h.controller.lastRecoveryDecision)
        #expect(decision.strategy == .freshObservation)
        #expect(h.controller.executionCount == 1, "Recovery must never re-dispatch the mutating action by itself")
        let trace = try #require(h.controller.activeRunTrace)
        #expect(trace.events.contains { $0.eventType == .failureClassified && $0.failureClass == .xctestFailed })
        #expect(trace.events.contains { $0.eventType == .recoveryDecided })
    }

    @Test("Verification failure is classified and leads to fresh observation, not blind retry")
    func testVerificationFailureRecovery() async throws {
        let h = RunHarness()
        h.begin()
        let s0 = ProductFixtures.observation("v0", [ProductFixtures.dropdown])
        let stillClosed = ProductFixtures.observation("v1", [ProductFixtures.dropdown])   // modal never appeared
        await h.runStep(target: ProductFixtures.dropdown, before: s0, after: stillClosed)
        #expect(h.controller.lastFailureClass == .verificationFailed)
        #expect(h.controller.lastRecoveryDecision?.strategy == .freshObservation)
        #expect(h.controller.executionCount == 1)
    }

    @Test("Repeated failures walk the ladder and then fail closed")
    func testRepeatedFailuresFailClosed() throws {
        let h = RunHarness()
        h.begin()
        var decisions: [RecoveryDecision] = []
        for _ in 0..<8 { decisions.append(h.controller.noteFailure(.observationFailed, detail: "obs failed")) }
        let last = try #require(decisions.last)
        if case .failClosed = last.action {} else { Issue.record("must fail closed, got \(last.action)") }
        #expect(decisions.filter { if case .captureFreshObservation = $0.action { return true } else { return false } }.count == 1)
        #expect(h.controller.activeRunTrace?.events.contains { $0.eventType == .budgetExceeded } == true)
    }

    @Test("Denial is terminal and dispatch after denial never touches the driver")
    func testDenialTerminal() async throws {
        let h = RunHarness()
        h.begin()
        let s0 = ProductFixtures.observation("n0", [ProductFixtures.dropdown])
        h.controller.recordObservation(s0)
        let proposal = ActionProposal(scenarioID: h.scenario.id, snapshotID: s0.snapshotID, elementID: "elem_29", expectedRole: "button",
                                      expectedIdentifier: "change-language-dropdown-button", toolName: "tap_element", reason: "r")
        _ = h.controller.handleProposal(proposal)
        h.controller.denyCurrentStep()
        if case .failClosed = h.controller.lastRecoveryDecision?.action {} else { Issue.record("denial must fail closed") }
        let result = await h.controller.dispatchCurrentStep(driver: h.driver, toolRegistry: h.registry)
        if case .success = result { Issue.record("must not dispatch after denial") }
        #expect((await h.driver.invokedActionCount["tap"] ?? 0) == 0)
    }

    @Test("Recovery planning never invokes the driver, whatever the failure")
    func testRecoveryNeverTouchesDriver() async {
        let h = RunHarness()
        h.begin()
        h.controller.recordObservation(ProductFixtures.observation("r", [ProductFixtures.dropdown]))
        for failure in FailureClass.allCases { h.controller.noteFailure(failure, detail: "x") }
        #expect(await h.driver.invokedActionCount.values.reduce(0, +) == 0)
        #expect(h.controller.executionCount == 0)
    }

    @Test("xcodebuild interruption is an XCTEST_FAILED, not an app crash")
    func testXcodebuildInterruption() {
        let c = FailureClassifier()
        #expect(c.classifyMessage("xcodebuild test exited with status code 143 (terminated unexpectedly)") == .xctestFailed)
        #expect(c.classifyMessage("The app terminated unexpectedly") == .appCrashed)
    }
}

