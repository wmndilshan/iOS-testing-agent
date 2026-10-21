import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

final class MockNetworkTransport: LLMNetworkTransportProtocol, @unchecked Sendable {
    var responses: [Result<(Data, HTTPURLResponse), Error>] = []
    private(set) var callCount: Int = 0
    private(set) var recordedRequests: [URLRequest] = []

    init(responses: [Result<(Data, HTTPURLResponse), Error>] = []) {
        self.responses = responses
    }

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        recordedRequests.append(request)
        if responses.isEmpty {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), resp)
        }
        let next = responses.removeFirst()
        switch next {
        case .success(let pair):
            return pair
        case .failure(let error):
            throw error
        }
    }
}
