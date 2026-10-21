import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Bounded condition waiter")
struct ConditionWaiterTests {

    @Test func testAlreadySatisfiedNeverSleeps() async throws {
        let clock = TestClock()
        let r = try await ConditionWaiter(clock: clock).wait(timeout: 5, pollInterval: 0.5) { true }
        #expect(r.satisfied && r.polls == 1 && clock.sleepCalls.isEmpty)
    }

    @Test func testSatisfiedAfterSeveralPollsUsesOnlyTheInjectedClock() async throws {
        let clock = TestClock()
        var n = 0
        let r = try await ConditionWaiter(clock: clock).wait(timeout: 5, pollInterval: 0.5) { n += 1; return n == 4 }
        #expect(r.satisfied && r.polls == 4)
        #expect(clock.sleepCalls == [0.5, 0.5, 0.5])
    }

    @Test func testNeverSatisfiedStopsWithinTheTimeoutBudget() async throws {
        let clock = TestClock()
        let r = try await ConditionWaiter(clock: clock).wait(timeout: 2, pollInterval: 0.5) { false }
        #expect(!r.satisfied && r.polls == 5)
        #expect(clock.sleepCalls.reduce(0, +) <= 2.0 + 1e-9, "total waiting never exceeds the timeout")
    }

    @Test func testPollCountIsCappedRegardlessOfTimeoutOrTinyIntervals() async throws {
        let clock = TestClock()
        var calls = 0
        let r = try await ConditionWaiter(clock: clock).wait(timeout: 60, pollInterval: 0.001) { calls += 1; return false }
        #expect(!r.satisfied && calls == ConditionWaiter.maximumPolls && r.polls == ConditionWaiter.maximumPolls)
        #expect(clock.sleepCalls.allSatisfy { $0 >= ConditionWaiter.minimumPollInterval - 1e-9 })
    }

    @Test func testConditionErrorsPropagate() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { _ = try await ConditionWaiter(clock: TestClock()).wait(timeout: 1, pollInterval: 0.5) { throw Boom() } }
    }
}
