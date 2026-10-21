import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("4. Backoff and Retry-After Tests with TestClock")
struct BackoffAndRetryAfterTests {
    let dummyURL = URL(string: "https://api.example.com/generate")!
    var request: URLRequest { URLRequest(url: dummyURL) }

    func makeResponse(statusCode: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: dummyURL, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
    }

    @Test func testExponentialBackoff() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("500".utf8), makeResponse(statusCode: 500))),
            .success((Data("500".utf8), makeResponse(statusCode: 500))),
            .success((Data("500".utf8), makeResponse(statusCode: 500))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        let policy = BackoffPolicy(initialDelay: 1.0, maxDelay: 10.0, maxAttempts: 4)
        let gateway = LLMGateway(transport: transport, backoffPolicy: policy, clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(clock.sleepCalls == [1.0, 2.0, 4.0], "Delays must follow exponential backoff sequence [1s, 2s, 4s].")
    }

    @Test func testBackoffIsCapped() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("500".utf8), makeResponse(statusCode: 500))),
            .success((Data("500".utf8), makeResponse(statusCode: 500))),
            .success((Data("500".utf8), makeResponse(statusCode: 500))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        // Capped at 3.0s
        let policy = BackoffPolicy(initialDelay: 2.0, maxDelay: 3.0, maxAttempts: 4)
        let gateway = LLMGateway(transport: transport, backoffPolicy: policy, clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(clock.sleepCalls == [2.0, 3.0, 3.0], "Delays must be capped at maxDelay (3.0s).")
    }

    @Test func testRetryAfterIsRespected() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("429".utf8), makeResponse(statusCode: 429, headers: ["Retry-After": "5"]))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        let policy = BackoffPolicy(initialDelay: 1.0, maxDelay: 10.0, maxAttempts: 3)
        let gateway = LLMGateway(transport: transport, backoffPolicy: policy, clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(clock.sleepCalls == [5.0], "Retry-After header value of 5 seconds must be used.")
    }

    @Test func testRetryAfterFallsBackToBackoff() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            // 429 without Retry-After header
            .success((Data("429".utf8), makeResponse(statusCode: 429))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        let policy = BackoffPolicy(initialDelay: 1.5, maxDelay: 8.0, maxAttempts: 3)
        let gateway = LLMGateway(transport: transport, backoffPolicy: policy, clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(clock.sleepCalls == [1.5], "Must fall back to exponential backoff when Retry-After is absent.")
    }
}

// MARK: - 5. Required Tests: Security Boundary & Policy (Section 24)
