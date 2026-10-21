import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Run lifecycle coordinator")
struct RunLifecycleCoordinatorTests {

    @Test func testFinishEmitsTerminalEventExactlyOnce() {
        var coordinator = RunLifecycleCoordinator()
        var finished: [RunTrace] = []
        coordinator.onRunFinished = { finished.append($0) }
        var trace: RunTrace? = RunTrace(scenarioID: "S")

        coordinator.finish(trace: &trace, stepID: nil, result: "COMPLETED")
        coordinator.finish(trace: &trace, stepID: nil, result: "FAILED")

        #expect(finished.count == 1)
        #expect(trace?.events.filter { $0.eventType == .runFinished }.count == 1)
    }

    @Test func testBeginRunAllowsTheNextRunToFinish() {
        var coordinator = RunLifecycleCoordinator()
        var count = 0
        coordinator.onRunFinished = { _ in count += 1 }
        var trace: RunTrace? = RunTrace(scenarioID: "S")
        coordinator.finish(trace: &trace, stepID: nil, result: "COMPLETED")
        coordinator.beginRun()
        var next: RunTrace? = RunTrace(scenarioID: "S")
        coordinator.finish(trace: &next, stepID: nil, result: "COMPLETED")
        #expect(count == 2)
    }

    @Test func testFinishWithoutATraceIsHarmless() {
        var coordinator = RunLifecycleCoordinator()
        var trace: RunTrace? = nil
        coordinator.finish(trace: &trace, stepID: nil, result: "CANCELLED")
        #expect(trace == nil)
    }
}
