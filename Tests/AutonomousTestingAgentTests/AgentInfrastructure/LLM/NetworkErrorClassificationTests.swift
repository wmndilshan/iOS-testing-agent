import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("3. Network Error Classification Tests")
struct NetworkErrorClassificationTests {
    let dummyURL = URL(string: "https://api.example.com/generate")!
    var request: URLRequest { URLRequest(url: dummyURL) }

    func makeResponse(statusCode: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: dummyURL, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
    }

    @Test func testTimeoutRetries() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .success((Data("{}".utf8), makeResponse(statusCode: 200)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 3), clock: clock)

        let data = try await gateway.execute(request: request)
        #expect(!data.isEmpty)
        #expect(transport.callCount == 3)
        #expect(clock.sleepCalls.count == 2)
    }

    @Test func testConnectionFailureRetries() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .failure(URLError(.networkConnectionLost)),
            .success((Data("{}".utf8), makeResponse(statusCode: 200)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 3), clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(transport.callCount == 2)
        #expect(clock.sleepCalls.count == 1)
    }

    @Test func testHTTP500Retries() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("error".utf8), makeResponse(statusCode: 500))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 3), clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(transport.callCount == 2)
    }

    @Test func testHTTP502Retries() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("bad gateway".utf8), makeResponse(statusCode: 502))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 3), clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(transport.callCount == 2)
    }

    @Test func testHTTP503Retries() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("unavailable".utf8), makeResponse(statusCode: 503))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 3), clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(transport.callCount == 2)
    }

    @Test func testHTTP504Retries() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("gateway timeout".utf8), makeResponse(statusCode: 504))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 3), clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(transport.callCount == 2)
    }

    @Test func testHTTP429Retries() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("rate limit".utf8), makeResponse(statusCode: 429, headers: ["Retry-After": "2"]))),
            .success((Data("ok".utf8), makeResponse(statusCode: 200)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 3), clock: clock)

        let _ = try await gateway.execute(request: request)
        #expect(transport.callCount == 2)
        #expect(clock.sleepCalls.first == 2.0)
    }

    @Test func testHTTP400DoesNotRetry() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("bad request".utf8), makeResponse(statusCode: 400)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 4), clock: clock)

        await #expect(throws: LLMNetworkError.self) {
            try await gateway.execute(request: request)
        }
        #expect(transport.callCount == 1, "HTTP 400 must NOT be retried.")
        #expect(clock.sleepCalls.isEmpty)
    }

    @Test func testHTTP401DoesNotBlindlyRetry() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("unauthorized".utf8), makeResponse(statusCode: 401)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 4), clock: clock)

        await #expect(throws: LLMNetworkError.self) {
            try await gateway.execute(request: request)
        }
        #expect(transport.callCount == 1, "HTTP 401 must NOT be blindly retried.")
        #expect(clock.sleepCalls.isEmpty)
    }

    @Test func testHTTP403DoesNotBlindlyRetry() async throws {
        let clock = TestClock()
        let transport = MockNetworkTransport(responses: [
            .success((Data("forbidden".utf8), makeResponse(statusCode: 403)))
        ])
        let gateway = LLMGateway(transport: transport, backoffPolicy: BackoffPolicy(maxAttempts: 4), clock: clock)

        await #expect(throws: LLMNetworkError.self) {
            try await gateway.execute(request: request)
        }
        #expect(transport.callCount == 1, "HTTP 403 must NOT be blindly retried.")
        #expect(clock.sleepCalls.isEmpty)
    }
}

// MARK: - 4. Required Tests: Exponential Backoff & Retry-After (Section 23)
