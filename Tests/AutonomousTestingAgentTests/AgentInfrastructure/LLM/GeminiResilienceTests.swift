import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Gemini resilience")
struct GeminiResilienceTests {

    // MARK: Budgets

    // MARK: Accounting

    // MARK: Classification of every failure kind

    @Test("Every Gemini failure mode classifies to its own kind")
    func testFailureKinds() {
        let table: [(Error, LLMFailureKind)] = [
            (LLMNetworkError.rateLimited(statusCode: 429, retryAfter: nil, message: ""), .rateLimited),
            (LLMError.httpError(statusCode: 429, message: ""), .rateLimited),
            (LLMNetworkError.serverError(statusCode: 503, message: ""), .serverError),
            (LLMError.httpError(statusCode: 500, message: ""), .serverError),
            (LLMNetworkError.timeout("t"), .timeout),
            (LLMError.networkError("Request timed out: x"), .timeout),
            (LLMNetworkError.connectionFailure("c"), .connectionFailure),
            (LLMError.networkError("Connection failed: x"), .connectionFailure),
            (LLMNetworkError.unauthorized(statusCode: 401, message: ""), .authentication),
            (LLMError.httpError(statusCode: 403, message: ""), .authentication),
            (LLMNetworkError.badRequest(statusCode: 400, message: ""), .badRequest),
            (LLMError.decodingError("bad"), .invalidJSON),
            (LLMError.emptyResponse, .emptyResponse),
            (LLMError.noCandidates("none"), .emptyResponse),
        ]
        for (error, kind) in table { #expect(LLMFailureKind.classify(error) == kind, "\(error)") }
    }

    // MARK: Real gateway behavior

    @Test("HTTP 429 then 200: the transport retries and the caller sees success")
    func testRetryOn429() async throws {
        let t = FakeTransport([.response(429, "slow down"), .response(429, "slow down"), .response(200, geminiBody(text: "ok"))])
        let clock = TestClock()
        let client = makeClient(t, clock: clock, attempts: 4)
        #expect(try await client.sendPrompt("p") == "ok")
        #expect(t.sendCount == 3)
        #expect(clock.sleepCalls.count == 2, "Backoff sleeps between retries")
    }

    @Test("HTTP 500 and timeouts are retried a bounded number of times, then surface")
    func testBoundedRetriesOn5xxAndTimeout() async {
        let t500 = FakeTransport([.response(500, "x"), .response(500, "x"), .response(500, "x"), .response(500, "x")])
        await #expect(throws: LLMError.self) { _ = try await makeClient(t500, attempts: 3).sendPrompt("p") }
        #expect(t500.sendCount == 3)

        let tTimeout = FakeTransport(Array(repeating: .error(URLError(.timedOut)), count: 5))
        await #expect(throws: LLMError.self) { _ = try await makeClient(tTimeout, attempts: 2).sendPrompt("p") }
        #expect(tTimeout.sendCount == 2)
    }

    @Test("Non-retryable HTTP errors (400/401/403/404) are not retried")
    func testNoRetryOnClientErrors() async {
        for code in [400, 401, 403, 404] {
            let t = FakeTransport([.response(code, "no"), .response(200, geminiBody(text: "should not be reached"))])
            await #expect(throws: LLMError.self) { _ = try await makeClient(t).sendPrompt("p") }
            #expect(t.sendCount == 1, "HTTP \(code) must not be retried")
        }
    }

    @Test("Empty and non-JSON responses are classified, not crashed on")
    func testEmptyAndInvalid() async {
        let empty = makeClient(FakeTransport([.response(200, "{\"candidates\":[]}")]))
        do { _ = try await empty.sendPrompt("p"); Issue.record("expected throw") }
        catch { #expect(LLMFailureKind.classify(error) == .emptyResponse) }

        let garbage = makeClient(FakeTransport([.response(200, "<html>not json</html>")]))
        do { _ = try await garbage.sendPrompt("p"); Issue.record("expected throw") }
        catch { #expect(LLMFailureKind.classify(error) == .invalidJSON) }
    }

    // MARK: Proposal pipeline





    // MARK: Network retry != execution retry

}
