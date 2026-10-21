import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("44. Structured RunTrace Tests")
@MainActor
struct RunTraceProductTests {

    @Test("A full run records every stage of the trusted spine for every step")
    func testEveryStageRecorded() async throws {
        let h = RunHarness()
        _ = await h.fullRun()
        let trace = try #require(h.controller.activeRunTrace)
        let types = Set(trace.events.map(\.eventType))
        for required in [RunTraceEventType.runStarted, .proposalReceived, .proposalValidated, .approvalRequested, .approvalGranted, .tokenIssued,
                         .executionStarted, .executionFinished, .postObserved, .verificationPassed, .scenarioCompleted, .runFinished] {
            #expect(types.contains(required), "Missing trace event \(required)")
        }
        for step in h.scenario.steps {
            let stepTypes = Set(trace.events(forStep: step.id).map(\.eventType))
            #expect(stepTypes.contains(.proposalValidated) && stepTypes.contains(.executionStarted) && stepTypes.contains(.verificationPassed), "step \(step.id)")
        }
    }

    @Test("Events per step occur in spine order")
    func testSpineOrder() async throws {
        let h = RunHarness()
        _ = await h.fullRun()
        let trace = try #require(h.controller.activeRunTrace)
        let order: [RunTraceEventType] = [.proposalReceived, .proposalValidated, .approvalRequested, .approvalGranted, .tokenIssued,
                                          .executionStarted, .executionFinished, .postObserved, .verificationPassed]
        let step0 = trace.events(forStep: h.scenario.steps[0].id).map(\.eventType)
        var last = -1
        for type in order {
            let idx = try #require(step0.firstIndex(of: type), "\(type) missing")
            #expect(idx > last, "\(type) out of order")
            last = idx
        }
    }

    @Test("Token IDs and proposal fingerprints correlate across approval and execution events")
    func testTokenCorrelation() async throws {
        let h = RunHarness()
        _ = await h.fullRun()
        let trace = try #require(h.controller.activeRunTrace)
        let granted = try #require(trace.events.first(where: { $0.eventType == .approvalGranted }))
        let started = try #require(trace.events.first(where: { $0.eventType == .executionStarted }))
        let verified = try #require(trace.events.first(where: { $0.eventType == .verificationPassed }))
        #expect(granted.tokenID != nil && granted.tokenID == started.tokenID && started.tokenID == verified.tokenID)
        #expect(granted.proposalFingerprint != nil && granted.proposalFingerprint == started.proposalFingerprint)
        #expect(UUID(uuidString: granted.tokenID ?? "") != nil)
    }

    @Test("Execution and verification events carry durations; observations carry snapshot IDs")
    func testDurationsAndSnapshots() async throws {
        let h = RunHarness()
        let (s0, s1, _) = await h.fullRun()
        let trace = try #require(h.controller.activeRunTrace)
        #expect(trace.events.filter { $0.eventType == .executionFinished }.allSatisfy { $0.durationSeconds != nil })
        #expect(trace.events.filter { $0.eventType == .verificationPassed }.allSatisfy { $0.durationSeconds != nil })
        #expect(trace.events.contains { $0.eventType == .proposalValidated && $0.snapshotID == s0.snapshotID })
        #expect(trace.events.contains { $0.eventType == .postObserved && $0.snapshotID == s1.snapshotID })
    }

    @Test("Run context: app, simulator, mode, start and end times are recorded")
    func testRunContext() async throws {
        let h = RunHarness()
        _ = await h.fullRun()
        let trace = try #require(h.controller.activeRunTrace)
        #expect(trace.scenarioID == "SCENARIO-LANG-SHEET")
        #expect(trace.appIdentity?.bundleID == ProductFixtures.bundleID)
        #expect(trace.simulatorID == "SIM-1" && trace.simulatorName == "iPhone 17")
        #expect(trace.executionMode == "NON_LIVE_TEST")
        #expect(trace.startedAt != nil && trace.endedAt != nil)
        #expect((trace.durationSeconds ?? -1) >= 0)
        #expect(!trace.runID.isEmpty)
    }

    @Test("The run-finished callback fires exactly once, on completion")
    func testFinishedOnce() async throws {
        let h = RunHarness()
        var finished: [RunTrace] = []
        h.controller.onRunFinished = { finished.append($0) }
        _ = await h.fullRun()
        h.controller.finishRun(result: "COMPLETED")   // must be a no-op
        h.controller.finishRun(result: "FAILED")
        #expect(finished.count == 1)
        #expect(finished.first?.events.filter { $0.eventType == .runFinished }.count == 1)
    }

    @Test("Denied approvals and expiry are traced with their failure class and token")
    func testDenialAndExpiryTraced() async throws {
        let h = RunHarness()
        h.begin()
        let s0 = ProductFixtures.observation("d0", [ProductFixtures.dropdown])
        h.controller.recordObservation(s0)
        let proposal = ActionProposal(scenarioID: h.scenario.id, snapshotID: s0.snapshotID, elementID: "elem_29", expectedRole: "button",
                                      expectedIdentifier: "change-language-dropdown-button", toolName: "tap_element", reason: "r")
        guard case .success(let req) = h.controller.handleProposal(proposal) else { Issue.record("rejected"); return }
        h.controller.denyCurrentStep(reason: "no")
        let trace = try #require(h.controller.activeRunTrace)
        let denied = try #require(trace.events.first(where: { $0.eventType == .approvalDenied }))
        #expect(denied.failureClass == .approvalDenied)
        #expect(denied.tokenID == req.id.uuidString)

        let h2 = RunHarness()
        h2.begin()
        let e0 = ProductFixtures.observation("e0", [ProductFixtures.dropdown])
        h2.controller.recordObservation(e0)
        let p2 = ActionProposal(scenarioID: h2.scenario.id, snapshotID: e0.snapshotID, elementID: "elem_29", expectedRole: "button",
                                expectedIdentifier: "change-language-dropdown-button", toolName: "tap_element", reason: "r")
        _ = h2.controller.handleProposal(p2)
        h2.controller.scenarioTimeoutSeconds = 600   // isolate the 120s approval TTL from the scenario timeout
        h2.clock.advance(by: 121)
        h2.controller.approveCurrentStep(source: .testAuthority)
        let t2 = try #require(h2.controller.activeRunTrace)
        #expect(t2.events.contains { $0.eventType == .approvalExpired && $0.failureClass == .approvalExpired })
        #expect(h2.controller.lastFailureClass == .approvalExpired)
    }

    @Test("Secrets passed into failure details never reach the trace")
    func testFailureDetailRedacted() async throws {
        let h = RunHarness()
        h.begin()
        h.controller.noteFailure(.unknown, detail: "login failed password=hunter2 key=AIzaSyD-1234567890abcdefghijklmnopqrstuv")
        let json = String(data: try JSONEncoder().encode(try #require(h.controller.activeRunTrace)), encoding: .utf8) ?? ""
        #expect(!json.contains("hunter2"))
        #expect(!json.contains("AIzaSyD-1234567890"))
    }

    @Test("Traces written before the product layer still decode")
    func testBackwardCompatibleDecode() throws {
        let legacy = """
        {"runID":"r1","scenarioID":"S","events":[{"id":"\(UUID().uuidString)","runID":"r1","scenarioID":"S","timestamp":700000000,"eventType":"OBSERVED","result":"ok"}]}
        """
        let trace = try JSONDecoder().decode(RunTrace.self, from: Data(legacy.utf8))
        #expect(trace.events.count == 1)
        #expect(trace.events[0].tokenID == nil && trace.events[0].failureClass == nil)
        #expect(trace.startedAt == nil)
    }

}

