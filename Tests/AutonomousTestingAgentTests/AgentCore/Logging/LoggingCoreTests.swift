import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Logging core model")
struct LoggingCoreTests {

    @Test func testLevelsAreOrderedAndLabelled() {
        let ordered: [LogLevel] = [.trace, .debug, .info, .notice, .warning, .error, .fault]
        #expect(LogLevel.allCases == ordered)
        #expect(ordered == ordered.sorted())
        #expect(LogLevel.warning > LogLevel.info)
        #expect(LogLevel(label: "notice") == .notice)
        #expect(LogLevel(label: "bogus") == nil)
        #expect(Set(ordered.map(\.label)).count == 7, "a small, distinct set of levels")
    }

    @Test func testCategoriesAreAClosedUniqueSet() {
        let raw = LogCategory.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count)
        for required in ["application", "lifecycle", "llm", "llm.network", "proposal", "validation", "approval", "authorization",
                         "execution", "tool", "xctest", "simulator", "observation", "verification", "recovery", "skills",
                         "persistence", "inspector", "integration", "security", "performance"] {
            #expect(raw.contains(required), "missing category \(required)")
        }
    }

    @Test func testEventNamesMustBeLowercaseDotted() {
        #expect(LogEvent.isValidName("execution.dispatch.started"))
        #expect(LogEvent.isValidName("llm.network.request.retry"))
        for bad in ["started", "Execution.Dispatch", "execution dispatch", "execution..x", "🚀.start", ""] {
            #expect(!LogEvent.isValidName(bad), "\(bad)")
        }
    }

    @Test func testMessagesAreSingleLinePlainTextWithoutEmoji() {
        let e = LogEvent(level: .info, category: .execution, event: "execution.step.started",
                         message: "🚀 Starting tap ✅\nnext line\t✓ done ⚠️")
        #expect(!e.message.contains("🚀") && !e.message.contains("✅") && !e.message.contains("⚠️") && !e.message.contains("✓"))
        #expect(!e.message.contains("\n") && !e.message.contains("\t"))
        #expect(e.message.contains("Starting tap") && e.message.contains("done"))
        let long = LogEvent(level: .info, category: .application, event: "app.long", message: String(repeating: "a", count: 2000))
        #expect(long.message.count <= LogText.maxMessageLength + 3)
    }

    @Test func testEventsCarryStructuredFieldsAndRoundTripThroughJSON() throws {
        let e = LogEvent(
            timestamp: Date(timeIntervalSince1970: 1_000), level: .notice, category: .authorization, event: "authorization.issued",
            message: "issued", context: LogContext(runID: "r", scenarioID: "s", stepID: "st", approvalID: "a", snapshotID: "snap", executionID: "x", toolName: "tap_element"),
            fields: ["attempt": 2, "ok": true, "ratio": 0.5, "nested": .object(["k": .array(["a", 1])])],
            durationSeconds: 0.25, errorClass: "APPROVAL_EXPIRED"
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(LogEvent.self, from: enc.encode(e))
        #expect(back == e)
        #expect(back.context.setFields.map(\.key) == ["runID", "scenarioID", "stepID", "approvalID", "snapshotID", "executionID", "toolName"])
    }

    @Test func testContextMergePrefersTheMoreSpecificValue() {
        let base = LogContext(runID: "r", scenarioID: "s", stepID: "old")
        let merged = base.merged(with: LogContext(stepID: "new", executionID: "x"))
        #expect(merged.runID == "r" && merged.scenarioID == "s" && merged.stepID == "new" && merged.executionID == "x")
    }

    @Test func testNullLoggerIsDisabledAndContextualLoggerAddsContext() {
        #expect(!NullLogger().isEnabled(.fault))
        let sink = InMemoryLogDestination()
        let base = DestinationLogger(minimumLevel: .trace, destinations: [sink])
        base.with(LogContext(runID: "run-1")).info(.lifecycle, "run.started", context: LogContext(stepID: "s0"))
        #expect(sink.events.first?.context.runID == "run-1")
        #expect(sink.events.first?.context.stepID == "s0")
    }

    @Test func testLogConfigurationLoadsFromEnvironmentInOnePlace() {
        let none = LogConfiguration.load(environment: [:])
        #expect(none == LogConfiguration(minimumLevel: .info, console: false, file: false, llmDiagnostics: false))
        let on = LogConfiguration.load(environment: ["ATA_LOG_LEVEL": "debug", "ATA_LOG_CONSOLE": "1", "ATA_LOG_FILE": "true", "ATA_LLM_DIAGNOSTICS": "yes"])
        #expect(on == LogConfiguration(minimumLevel: .debug, console: true, file: true, llmDiagnostics: true))
        #expect(LogConfiguration.load(environment: ["ATA_LOG_LEVEL": "nonsense"]).minimumLevel == .info)
    }
}
