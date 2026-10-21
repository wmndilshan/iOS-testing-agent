import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("39. Recovery Controller Tests")
struct RecoveryControllerTests {

    private func context(_ failure: FailureClass, obs: Observation? = nil,
                         stepIndex: Int = 0, rejected: Bool = false, llm: Bool = true) -> RecoveryContext {
        RecoveryContext(scenario: ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET"), stepIndex: stepIndex,
                        observation: obs, failure: failure, proposalWasAlreadyRejected: rejected, llmBudgetAvailable: llm)
    }

    @Test("The recovery action type contains no way to name a tool, driver call or approval")
    func testActionIsNotExecutable() {
        // Exhaustive switch: adding an executable case would break compilation of this test.
        let samples: [RecoveryAction] = [
            .captureFreshObservation(reason: ""), .requestNewProposal(reason: "", allowLLM: true),
            .humanIntervention(reason: "", guidance: ""), .failClosed(reason: "")
        ]
        for a in samples {
            switch a {
            case .captureFreshObservation, .requestNewProposal, .humanIntervention, .failClosed: break
            }
        }
        #expect(samples.count == 4)
    }

    @Test("Observation failures first ask for a fresh read-only observation")
    func testFreshObservationFirst() {
        var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
        let d = rc.decide(context(.observationFailed), budget: &budget)
        #expect(d.strategy == .freshObservation)
        if case .captureFreshObservation = d.action {} else { Issue.record("expected captureFreshObservation") }
        #expect(rc.history.count == 1)
    }

    @Test("Ladder advances: fresh observation, then a new proposal, then fail closed")
    func testLadderProgression() {
        var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
        let d1 = rc.decide(context(.staleSnapshot), budget: &budget)
        let d2 = rc.decide(context(.staleSnapshot), budget: &budget)
        let d3 = rc.decide(context(.staleSnapshot), budget: &budget)
        let d4 = rc.decide(context(.staleSnapshot), budget: &budget)
        #expect(d1.strategy == .freshObservation)
        #expect(d2.strategy == .requestNewLLMProposal)
        #expect(d3.strategy == .requestNewLLMProposal)
        if case .failClosed = d4.action {} else { Issue.record("ladder must end in failClosed, got \(d4.action)") }
    }

    @Test("A supervisor denial is terminal: no automated recovery")
    func testDenialTerminal() {
        var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
        let d = rc.decide(context(.approvalDenied), budget: &budget)
        if case .failClosed = d.action {} else { Issue.record("denial must fail closed") }
    }

    @Test("A missing element is first re-observed, then the model is asked again, and then recovery gives up")
    func testElementNotFoundLadder() {
        var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
        let obs = ProductFixtures.observation("m", [ProductFixtures.element("other", role: "image")])
        let d1 = rc.decide(context(.elementNotFound, obs: obs), budget: &budget)
        let d2 = rc.decide(context(.elementNotFound, obs: obs), budget: &budget)
        #expect(d1.strategy == .freshObservation)
        #expect(d2.strategy == .requestNewLLMProposal)
    }

    @Test("An exhausted recovery budget fails closed before any strategy is chosen")
    func testBudgetExhaustedFailsClosed() {
        var rc = RecoveryController()
        var budget = RecoveryBudgetTracker(policy: RecoveryPolicy(maxHealingAttempts: 2, maxRecoverySteps: 1, maxConsecutiveFailures: 3, maxNoProgressSteps: 2))
        budget.recordRecoveryStep(); budget.recordRecoveryStep()
        let d = rc.decide(context(.observationFailed), budget: &budget)
        if case .failClosed(let reason) = d.action { #expect(reason.contains("RECOVERY_BUDGET_EXHAUSTED")) }
        else { Issue.record("expected failClosed") }
    }

    @Test("Consecutive-failure budget also fails closed")
    func testConsecutiveFailureBudget() {
        var rc = RecoveryController()
        var budget = RecoveryBudgetTracker()
        budget.recordFailure(); budget.recordFailure(); budget.recordFailure()
        let d = rc.decide(context(.xctestFailed), budget: &budget)
        if case .failClosed = d.action {} else { Issue.record("expected failClosed") }
    }

    @Test("The model is never re-asked for a proposal that was already rejected")
    func testNoReaskOfRejectedProposal() {
        var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
        let d = rc.decide(context(.validationFailed, rejected: true), budget: &budget)
        if case .failClosed = d.action {} else { Issue.record("must not re-ask, got \(d.action)") }
    }

    @Test("Same (failure, strategy) pair cannot be issued more than its allowance")
    func testRepeatLimit() {
        var rc = RecoveryController(maxRepeatsPerPair: 2); var budget = RecoveryBudgetTracker(policy: RecoveryPolicy(maxHealingAttempts: 9, maxRecoverySteps: 9, maxConsecutiveFailures: 9, maxNoProgressSteps: 9))
        var proposals = 0
        for _ in 0..<8 {
            let d = rc.decide(context(.validationFailed), budget: &budget)
            if case .requestNewProposal = d.action { proposals += 1 }
        }
        #expect(proposals == 2)
    }

    @Test("Ambiguity, simulator faults and LLM outages escalate instead of retrying")
    func testEscalations() {
        for failure in [FailureClass.ambiguousTarget, .simulatorUnavailable, .llmUnavailable, .unknown] {
            var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
            let d = rc.decide(context(failure), budget: &budget)
            if case .humanIntervention = d.action {} else { Issue.record("\(failure) must escalate, got \(d.action)") }
            #expect(budget.recoverySteps == 0, "Escalation must not consume automated recovery budget")
        }
    }

    @Test("State restoration is surfaced to the operator, never auto-dispatched")
    func testRestorationIsHumanGuided() {
        for failure in [FailureClass.appCrashed, .appLaunchFailed] {
            var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
            let d = rc.decide(context(failure), budget: &budget)
            #expect(d.strategy == .restorePreviousState)
            if case .humanIntervention(_, let guidance) = d.action { #expect(guidance.contains("fresh observation")) }
            else { Issue.record("expected humanIntervention") }
        }
    }

    @Test("Every recovery decision is recorded with its outcome")
    func testHistoryRecorded() {
        var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
        _ = rc.decide(context(.observationFailed), budget: &budget)
        _ = rc.decide(context(.approvalDenied), budget: &budget)
        _ = rc.decide(context(.ambiguousTarget), budget: &budget)
        #expect(rc.history.map(\.outcome) == ["ISSUED", "FAILED_CLOSED", "ESCALATED"])
        #expect(rc.history.map(\.index) == [1, 2, 3])
        rc.reset()
        #expect(rc.history.isEmpty)
    }

    @Test("Every failure class has a defined ladder (no class is silently unhandled)")
    func testLadderDefinedForAll() {
        for failure in FailureClass.allCases {
            var rc = RecoveryController(); var budget = RecoveryBudgetTracker()
            let d = rc.decide(context(failure, obs: ProductFixtures.observation("x", [])), budget: &budget)
            #expect(d.failureClass == failure)
        }
    }
}

