import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("iOS action logging")
struct IOSActionLoggingTests {

    private func run(_ action: IOSAction, obs: Observation, driver: SimulatedDriver? = nil) async -> (InMemoryLogDestination, Error?) {
        let sink = InMemoryLogDestination()
        let d = driver ?? SimulatedDriver(currentSnapshot: obs)
        let executor = IOSTestSupport.executor(driver: d, logger: DestinationLogger(minimumLevel: .trace, destinations: [sink]))
        let context = IOSActionContext(toolName: "tap_element", executionID: "exec-9", log: LogContext(runID: "run-1", scenarioID: "S1", stepID: "step-1"))
        do { _ = try await executor.execute(action, context: context); return (sink, nil) } catch { return (sink, error) }
    }

    @Test func testSuccessfulActionEmitsStartedAndCompletedWithCorrelation() async {
        let obs = IOSTestSupport.snapshot()
        let (sink, error) = await run(.tap(TapAction(target: IOSTestSupport.target(obs, "ok"))), obs: obs)
        #expect(error == nil)
        #expect(sink.events.map(\.event) == ["ios.action.started", "ios.action.completed"])
        for e in sink.events {
            #expect(e.context.runID == "run-1" && e.context.scenarioID == "S1" && e.context.stepID == "step-1")
            #expect(e.context.executionID == "exec-9" && e.context.toolName == "tap_element")
            #expect(e.fields["actionType"] == "tap")
        }
        #expect(sink.events[1].durationSeconds != nil && sink.events[1].fields["success"] == true && sink.events[1].level == .info)
    }

    @Test func testFailedActionEmitsAClassifiedErrorAndStillThrows() async {
        let obs = IOSTestSupport.snapshot()
        let (sink, error) = await run(.tap(TapAction(target: ElementTarget(snapshotID: "stale", elementID: "ok"))), obs: obs)
        #expect(error as? DriverError != nil)
        let failed = sink.events.last
        #expect(failed?.event == "ios.action.failed" && failed?.level == .error && failed?.errorClass == "staleSnapshot")
    }

    @Test func testTypedTextNeverAppearsInAnyLogEvent() async throws {
        let obs = IOSTestSupport.snapshot()
        let (sink, _) = await run(.typeText(TypeTextAction(target: IOSTestSupport.target(obs, "field"), text: "LOGGED-SECRET-789")), obs: obs)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dump = sink.events.compactMap { try? String(data: enc.encode($0), encoding: .utf8) }.joined()
        #expect(!dump.isEmpty && !dump.contains("LOGGED-SECRET-789"))
    }

    @Test func testObservationCapabilitiesLogObservationEvents() async {
        let obs = IOSTestSupport.snapshot()
        let (sink, _) = await run(.accessibilityTree(AccessibilityTreeAction(bundleID: ProductFixtures.bundleID)), obs: obs)
        let names = sink.events.map(\.event)
        #expect(names == ["ios.action.started", "ios.observation.started", "ios.observation.completed", "ios.action.completed"])
        #expect(sink.events[2].context.snapshotID == obs.snapshotID && sink.events[2].fields["elementCount"] == .int(obs.elements.count))
    }

    @Test func testAdapterLogsValidationBeforeExecution() async throws {
        let obs = IOSTestSupport.snapshot()
        let sink = InMemoryLogDestination()
        let logger = DestinationLogger(minimumLevel: .trace, destinations: [sink])
        let adapter = IOSToolAdapter(executor: IOSTestSupport.executor(driver: SimulatedDriver(currentSnapshot: obs), logger: logger), logger: logger)
        let call = ToolCall(id: "c", name: "tap_element", arguments: ["snapshotID": .string(obs.snapshotID), "elementID": "ok"])
        _ = try await adapter.execute(try ToolResolver().resolve(call), context: IOSActionContext(toolName: "tap_element", executionID: "e"))
        #expect(sink.events.map(\.event) == ["ios.action.validated", "ios.action.started", "ios.action.completed"])
    }

    @Test func testLoggingNeverChangesTheResult() async throws {
        let obs = IOSTestSupport.snapshot()
        let quiet = try await IOSTestSupport.executor(driver: SimulatedDriver(currentSnapshot: obs))
            .execute(.tap(TapAction(target: IOSTestSupport.target(obs, "ok"))), context: IOSActionContext(toolName: "t", executionID: "e"))
        let loud = try await IOSTestSupport.executor(driver: SimulatedDriver(currentSnapshot: obs), logger: DestinationLogger(minimumLevel: .trace, destinations: [InMemoryLogDestination()]))
            .execute(.tap(TapAction(target: IOSTestSupport.target(obs, "ok"))), context: IOSActionContext(toolName: "t", executionID: "e"))
        #expect(quiet.output.summary == loud.output.summary && quiet.result.success == loud.result.success && quiet.result.actionType == loud.result.actionType)
    }
}
