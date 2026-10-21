import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("47. Run History & Replay Tests")
@MainActor
struct RunHistoryTests {

    @Test("A record is derived from the trace: counts, verification, mode")
    func testRecordFromTrace() async throws {
        let h = RunHarness()
        _ = await h.fullRun()
        let trace = try #require(h.controller.activeRunTrace)
        let record = RunHistoryRecord.make(from: trace, humanApproved: false)
        #expect(record.runID == trace.runID)
        #expect(record.scenarioID == "SCENARIO-LANG-SHEET")
        #expect(record.result == "COMPLETED")
        #expect(record.stepCount == 2)
        #expect(record.recoveryCount == 0)
        #expect(record.verificationResult.hasPrefix("VERIFIED"))
        #expect(record.executionMode == "NON_LIVE_TEST")
        #expect(record.appBundleID == ProductFixtures.bundleID)
        #expect(record.humanApproved == false)
    }

    @Test("Failure, cancel and block outcomes are labelled from the trace")
    func testResultLabels() {
        var cancelled = RunTrace(scenarioID: "S"); cancelled.append(eventType: .scenarioCancelled, result: "x")
        var blocked = RunTrace(scenarioID: "S"); blocked.append(eventType: .budgetExceeded, result: "x")
        let failed = RunTrace(scenarioID: "S")
        #expect(RunHistoryRecord.make(from: cancelled, humanApproved: false).result == "CANCELLED")
        #expect(RunHistoryRecord.make(from: blocked, humanApproved: false).result == "BLOCKED")
        #expect(RunHistoryRecord.make(from: failed, humanApproved: false).result == "FAILED")
    }

    @Test("The store persists records and traces, newest first, and survives corrupt files")
    func testStorePersistence() async throws {
        let dir = ProductFixtures.tempDir()
        let store = RunHistoryStore(directory: dir)
        var older = RunTrace(scenarioID: "A", startedAt: Date(timeIntervalSince1970: 1000)); older.append(eventType: .scenarioCompleted, result: "ok"); older.finish()
        var newer = RunTrace(scenarioID: "B", startedAt: Date(timeIntervalSince1970: 2000)); newer.append(eventType: .scenarioCompleted, result: "ok"); newer.finish()
        try await store.save(record: RunHistoryRecord.make(from: older, humanApproved: false), trace: older)
        try await store.save(record: RunHistoryRecord.make(from: newer, humanApproved: true), trace: newer)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("garbage.record.json"))

        let listed = await store.list()
        #expect(listed.map(\.scenarioID) == ["B", "A"])
        #expect(listed.first?.humanApproved == true)
        #expect(await store.loadTrace(runID: newer.runID)?.events.count == 1)
        #expect(await store.loadTrace(runID: "missing") == nil)
    }

    @Test("Stored history never contains secrets")
    func testStoredHistoryHasNoSecrets() async throws {
        let dir = ProductFixtures.tempDir()
        let store = RunHistoryStore(directory: dir)
        var trace = RunTrace(scenarioID: "S")
        trace.append(eventType: .failureClassified, result: "password=hunter2 Bearer abcdefghijklmnop1234")
        trace.finish()
        try await store.save(record: RunHistoryRecord.make(from: trace, result: "FAILED password=hunter2", humanApproved: false), trace: trace)
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("hunter2") && !text.contains("abcdefghijklmnop1234"), "\(file.lastPathComponent)")
        }
    }

    @Test("Replay is only a request to start over: it carries no approval, token or tool call")
    func testReplayIsJustARequest() async throws {
        let dir = ProductFixtures.tempDir()
        let store = RunHistoryStore(directory: dir)
        var trace = RunTrace(scenarioID: "SCENARIO-LANG-SHEET"); trace.append(eventType: .scenarioCompleted, result: "ok"); trace.finish()
        try await store.save(record: RunHistoryRecord.make(from: trace, humanApproved: true), trace: trace)
        let request = try #require(await store.replayRequest(for: trace.runID))
        #expect(request.scenarioID == "SCENARIO-LANG-SHEET" && request.sourceRunID == trace.runID)
        #expect(request.requiresFreshObservation && request.requiresNewAuthorization)
        #expect(await store.replayRequest(for: "nope") == nil)
    }

    @Test("Starting a replayed scenario grants nothing: no approval, and dispatch is refused")
    func testReplayStartsWithNoAuthority() async throws {
        let h = RunHarness()
        _ = await h.fullRun()                             // original run, fully approved
        let request = ReplayRequest(sourceRunID: "old", scenarioID: h.scenario.id)
        #expect(h.controller.startScenario(id: request.scenarioID))
        #expect(h.controller.activeApproval == nil)
        #expect(h.controller.currentStepIndex == 0)
        let result = await h.controller.dispatchCurrentStep(driver: h.driver, toolRegistry: h.registry)
        if case .success = result { Issue.record("replay must not dispatch without a fresh approval") }
        #expect((await h.driver.invokedActionCount["tap"] ?? 0) == 2, "Only the two taps from the ORIGINAL run may exist")
    }
}

