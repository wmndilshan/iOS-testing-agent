import Foundation
import AgentCore

public protocol LLMNetworkTransportProtocol: Sendable {
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: LLMNetworkTransportProtocol {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMNetworkError.connectionFailure("Non-HTTP response received.")
        }
        return (data, httpResponse)
    }
}

// MARK: - LLMGateway
