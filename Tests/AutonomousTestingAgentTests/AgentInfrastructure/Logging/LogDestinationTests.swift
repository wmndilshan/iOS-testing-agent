import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Log destinations and factory")
struct LogDestinationTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("logtest-\(UUID().uuidString)").appendingPathComponent("agent.log.jsonl")
    }

    @Test func testLevelFilteringHappensBeforeAnyDestination() {
        let sink = InMemoryLogDestination()
        let logger = DestinationLogger(minimumLevel: .warning, destinations: [sink])
        logger.info(.application, "app.started")
        logger.warning(.application, "app.slow")
        logger.error(.application, "app.failed")
        #expect(sink.events.map(\.event) == ["app.slow", "app.failed"])
        #expect(!logger.isEnabled(.notice) && logger.isEnabled(.error))
    }

    @Test func testEveryDestinationReceivesTheSameRedactedEvent() {
        let a = InMemoryLogDestination(), b = InMemoryLogDestination()
        let logger = DestinationLogger(minimumLevel: .info, destinations: [a, b])
        logger.info(.llm, "llm.request.started", fields: ["apiKey": "secret-value"])
        #expect(a.events == b.events)
        #expect(a.events.first?.fields["apiKey"] == .string(LogRedactor.marker))
    }

    @Test func testFileDestinationWritesOneRedactedJSONObjectPerLine() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let logger = DestinationLogger(minimumLevel: .info, destinations: [FileLogDestination(url: url)])
        logger.info(.execution, "execution.dispatch.started", "go", context: LogContext(runID: "r1"), fields: ["password": "hunter2"])
        logger.error(.execution, "execution.step.failed", errorClass: "XCTEST_FAILED")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let events = try lines.map { try dec.decode(LogEvent.self, from: Data($0.utf8)) }
        #expect(events[0].context.runID == "r1" && events[1].errorClass == "XCTEST_FAILED")
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("hunter2"))
    }

    @Test func testConsoleLineFormatIsPlainStructuredText() {
        let line = LogLineFormatter.format(LogEvent(
            timestamp: Date(timeIntervalSince1970: 0), level: .warning, category: .llmNetwork, event: "llm.network.request.retry",
            message: "retrying", context: LogContext(requestID: "req-1"), fields: ["attempt": 2], errorClass: "HTTP_429"))
        #expect(line.contains("WARNING") && line.contains("llm.network") && line.contains("llm.network.request.retry"))
        #expect(line.contains("requestID=req-1") && line.contains("attempt=2") && line.contains("errorClass=HTTP_429"))
        #expect(line.unicodeScalars.allSatisfy { $0.value < 0x80 }, "console lines are plain ASCII")
    }

    @Test func testFactoryCreatesNothingWhenEveryDestinationIsOff() {
        let logger = LoggerFactory.make(LogConfiguration(), fileURL: tempFile())
        #expect(!logger.isEnabled(.fault), "no destinations: nothing is written, nothing is created")
    }

    @Test func testFactoryFileDestinationOnlyWhenEnabledAndOnlyAtTheGivenURL() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let logger = LoggerFactory.make(LogConfiguration(minimumLevel: .info, file: true), fileURL: url)
        logger.info(.application, "app.started")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func testCompositionRootChoosesTheLogsDirectoryAndIsSilentByDefault() {
        let root = InfrastructureFactory(projectRoot: URL(fileURLWithPath: "/tmp/ata-root"))
        #expect(root.logsDirectory.path == "/tmp/ata-root/.logs")
        #expect(!root.makeLogger(LogConfiguration()).isEnabled(.fault))
    }
}
