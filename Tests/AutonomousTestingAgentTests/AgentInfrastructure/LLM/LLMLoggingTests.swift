import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("LLM and network logging")
struct LLMLoggingTests {

    private func makeLoggedClient(_ steps: [FakeTransport.Step], sink: InMemoryLogDestination) -> LLMClient {
        let logger = DestinationLogger(minimumLevel: .trace, destinations: [sink])
        let gateway = LLMGateway(
            transport: FakeTransport(steps),
            backoffPolicy: BackoffPolicy(initialDelay: 0.01, maxDelay: 0.05, maxAttempts: 3),
            clock: TestClock(), logger: logger, provider: "gemini"
        )
        return LLMClient(config: Configuration(apiKey: "AIzaSyD-1234567890abcdefghijklmnop", model: "m", projectRoot: URL(fileURLWithPath: "/tmp")),
                         gateway: gateway, logger: logger)
    }

    private func serialized(_ events: [LogEvent]) -> String {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        return events.compactMap { try? String(data: enc.encode($0), encoding: .utf8) }.joined(separator: "\n")
    }

    @Test func testSuccessfulRequestLogsSemanticAndTransportEventsExactlyOnceEach() async throws {
        let sink = InMemoryLogDestination()
        let client = makeLoggedClient([.response(200, geminiBody(text: "REPLY-SENTINEL"))], sink: sink)
        _ = try await client.sendPrompt("PROMPT-SENTINEL-123")
        let names = sink.events.map(\.event)
        #expect(names.filter { $0 == "llm.request.started" }.count == 1)
        #expect(names.filter { $0 == "llm.request.completed" }.count == 1)
        #expect(names.filter { $0 == "llm.network.request.started" }.count == 1, "one network owner, no duplicate transport logs")
        #expect(names.filter { $0 == "llm.network.request.completed" }.count == 1)
        let started = try #require(sink.events.first { $0.event == "llm.request.started" })
        #expect(started.fields["provider"] == "gemini" && started.fields["messageCount"] == 1)
        #expect(started.fields["promptChars"] == .int("PROMPT-SENTINEL-123".count))
        let completed = try #require(sink.events.first { $0.event == "llm.request.completed" })
        #expect(completed.fields["responseChars"] == .int("REPLY-SENTINEL".count) && completed.durationSeconds != nil)
    }

    @Test func testNetworkEventsShareOneRequestIDAndLeakNothing() async throws {
        let sink = InMemoryLogDestination()
        let client = makeLoggedClient([.response(200, geminiBody(text: "ok"))], sink: sink)
        _ = try await client.sendPrompt("PROMPT-SENTINEL-123")
        let net = sink.events.filter { $0.category == .llmNetwork }
        #expect(net.count == 2 && Set(net.compactMap(\.context.requestID)).count == 1)
        let dump = serialized(sink.events)
        for secret in ["AIzaSyD-1234567890abcdefghijklmnop", "PROMPT-SENTINEL-123", "x-goog-api-key", "Authorization"] {
            #expect(!dump.contains(secret), "\(secret) must never be logged")
        }
        #expect(!dump.contains("?"), "no URL query strings")
        let started = try #require(net.first)
        #expect(started.fields["endpoint"] == .string("generativelanguage.googleapis.com/v1beta/models/m:generateContent"))
        if case .int(let bytes)? = started.fields["payloadBytes"] { #expect(bytes > 0) } else { Issue.record("payloadBytes missing") }
    }

    @Test func testRetriesAndRateLimitsAreLoggedWithNeutralClassification() async throws {
        let sink = InMemoryLogDestination()
        let client = makeLoggedClient([.response(429, "slow down"), .response(503, "unavailable"), .response(200, geminiBody(text: "ok"))], sink: sink)
        _ = try await client.sendPrompt("p")
        let retries = sink.events.filter { $0.event == "llm.network.request.retry" }
        #expect(retries.count == 2 && retries.allSatisfy { $0.level == .warning })
        #expect(retries.map(\.errorClass) == ["HTTP_429", "HTTP_5XX"])
        #expect(retries.compactMap { $0.fields["attempt"] } == [1, 2])
    }

    @Test func testFailuresLogClassificationNeverTheResponseBody() async {
        let sink = InMemoryLogDestination()
        let client = makeLoggedClient([.response(401, "BODY-SENTINEL leaked detail")], sink: sink)
        await #expect(throws: Error.self) { _ = try await client.sendPrompt("p") }
        let failed = sink.events.filter { $0.event.hasSuffix(".failed") }
        #expect(failed.map(\.event).contains("llm.network.request.failed") && failed.map(\.event).contains("llm.request.failed"))
        #expect(failed.allSatisfy { $0.level == .error && $0.errorClass == "AUTHENTICATION" })
        #expect(!serialized(sink.events).contains("BODY-SENTINEL"))
    }

    @Test func testTimeoutsAndConnectionFailuresAreClassified() async {
        let sink = InMemoryLogDestination()
        let client = makeLoggedClient([.error(URLError(.timedOut)), .error(URLError(.timedOut)), .error(URLError(.timedOut))], sink: sink)
        await #expect(throws: Error.self) { _ = try await client.sendPrompt("p") }
        #expect(sink.events.contains { $0.event == "llm.network.request.failed" && $0.errorClass == "TIMEOUT" })
    }



    @Test func testLoggingIsNeutralAboutTheProvider() {
        // Application-level events use neutral names; only the provider *field* names Gemini.
        let names = ["llm.request.started", "llm.request.completed", "llm.response.received", "llm.response.parse_failed", "llm.proposal.created", "llm.proposal.rejected"]
        #expect(names.allSatisfy { LogEvent.isValidName($0) && !$0.contains("gemini") })
    }
}
