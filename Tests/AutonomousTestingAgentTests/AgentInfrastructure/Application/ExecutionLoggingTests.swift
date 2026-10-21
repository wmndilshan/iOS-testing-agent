import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Execution lifecycle logging")
@MainActor
struct ExecutionLoggingTests {

    private func run(logger: (any AppLogger)?) async -> (RunHarness, Result<ScenarioVerificationResult, DriverError>) {
        let h = RunHarness()
        if let logger { h.controller.logger = logger }
        h.begin()
        let s0 = ProductFixtures.observation("s0", [ProductFixtures.dropdown])
        let s1 = ProductFixtures.observation("s1", [ProductFixtures.closeButton])
        let r = await h.runStep(target: ProductFixtures.dropdown, before: s0, after: s1)
        return (h, r)
    }

    @Test func testTheFullLifecycleIsLoggedInOrderAndCorrelated() async throws {
        let sink = InMemoryLogDestination()
        _ = await run(logger: DestinationLogger(minimumLevel: .trace, destinations: [sink]))
        let names = sink.events.map(\.event)
        let expected = ["proposal.received", "proposal.validated", "approval.requested", "approval.approved", "authorization.issued",
                        "execution.dispatch.started", "execution.tool.started", "execution.tool.completed",
                        "execution.observation.completed", "execution.verification.completed"]
        var cursor = names.startIndex
        for e in expected {
            guard let idx = names[cursor...].firstIndex(of: e) else { Issue.record("missing or out of order: \(e) in \(names)"); return }
            cursor = idx + 1
        }
        let execution = sink.events.filter { $0.event.hasPrefix("execution.") || $0.event == "authorization.issued" }
        let executionIDs = Set(execution.compactMap(\.context.executionID))
        #expect(executionIDs.count == 1, "one executionID per dispatch, generated once by the controller")
        for e in execution {
            #expect(e.context.runID != nil && e.context.scenarioID == "SCENARIO-LANG-SHEET" && e.context.stepID != nil)
            #expect(e.context.snapshotID != nil && e.context.toolName == "tap_element")
        }
        #expect(sink.events.first { $0.event == "authorization.issued" }?.context.approvalID != nil)
    }

    @Test func testLevelsFollowTheDocumentedPolicy() async {
        let sink = InMemoryLogDestination()
        _ = await run(logger: DestinationLogger(minimumLevel: .trace, destinations: [sink]))
        let byName = Dictionary(uniqueKeysWithValues: sink.events.map { ($0.event, $0.level) })
        #expect(byName["approval.approved"] == .notice && byName["authorization.issued"] == .notice)
        #expect(byName["execution.dispatch.started"] == .info && byName["execution.tool.started"] == .debug)
    }

    @Test func testRefusedDispatchNeverLogsAnAuthorization() async {
        let sink = InMemoryLogDestination()
        let h = RunHarness()
        h.controller.logger = DestinationLogger(minimumLevel: .trace, destinations: [sink])
        h.begin()
        h.controller.recordObservation(ProductFixtures.observation("s0", [ProductFixtures.dropdown]))
        _ = await h.controller.dispatchCurrentStep(driver: h.driver, toolRegistry: h.registry)
        #expect(!sink.events.contains { $0.event == "authorization.issued" || $0.event == "execution.dispatch.started" })
    }

    @Test func testRejectedProposalsAndDeniedApprovalsAreLoggedWithNeutralClassification() async {
        let sink = InMemoryLogDestination()
        let h = RunHarness()
        h.controller.logger = DestinationLogger(minimumLevel: .trace, destinations: [sink])
        h.begin()
        let obs = ProductFixtures.observation("s0", [ProductFixtures.dropdown])
        h.controller.recordObservation(obs)
        let bad = ActionProposal(scenarioID: "OTHER", snapshotID: obs.snapshotID, elementID: "elem_29", expectedRole: "button", toolName: "tap_element", reason: "x")
        _ = h.controller.handleProposal(bad)
        let rejected = sink.events.first { $0.event == "proposal.rejected" }
        #expect(rejected?.level == .warning && rejected?.errorClass != nil)
    }

    @Test func testLoggingDoesNotChangeExecutionOutcomes() async {
        let (quiet, quietResult) = await run(logger: nil)
        let sink = InMemoryLogDestination()
        let (loud, loudResult) = await run(logger: DestinationLogger(minimumLevel: .trace, destinations: [sink]))
        #expect(!sink.events.isEmpty)
        switch (quietResult, loudResult) {
        case (.success(let a), .success(let b)): #expect(a.verified == b.verified && a.reason == b.reason)
        default: Issue.record("both runs must succeed identically")
        }
        #expect(quiet.controller.scenarioLifecycle == loud.controller.scenarioLifecycle)
        #expect(quiet.controller.completedStepCount == loud.controller.completedStepCount)
        #expect(await quiet.driver.invokedActionCount == (await loud.driver.invokedActionCount))
    }

    @Test func testNoExecutionEventContainsSecretsOrRawPayloads() async {
        let sink = InMemoryLogDestination()
        _ = await run(logger: DestinationLogger(minimumLevel: .trace, destinations: [sink]))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dump = sink.events.compactMap { try? String(data: enc.encode($0), encoding: .utf8) }.joined()
        for forbidden in ["password", "apiKey", "Authorization", "AIza"] { #expect(!dump.contains(forbidden), "\(forbidden)") }
    }
}
