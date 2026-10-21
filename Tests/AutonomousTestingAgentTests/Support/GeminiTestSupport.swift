import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

final class FakeTransport: LLMNetworkTransportProtocol, @unchecked Sendable {
    enum Step { case response(Int, String), error(Error) }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var sendCount = 0

    init(_ steps: [Step]) { self.steps = steps }

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step: Step = lock.withLock {
            sendCount += 1
            return steps.isEmpty ? .response(500, "exhausted") : steps.removeFirst()
        }
        switch step {
        case .error(let e): throw e
        case .response(let code, let body):
            let http = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: code, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        }
    }
}

func geminiBody(text: String? = nil, functionName: String? = nil, usage: (Int, Int)? = nil) -> String {
    var part = "{}"
    if let text { part = "{\"text\":\(String(data: (try? JSONEncoder().encode(text)) ?? Data(), encoding: .utf8) ?? "\"\"")}" }
    if let functionName { part = "{\"functionCall\":{\"name\":\"\(functionName)\",\"args\":{}}}" }
    var body = "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[\(part)]}}]"
    if let usage { body += ",\"usageMetadata\":{\"promptTokenCount\":\(usage.0),\"candidatesTokenCount\":\(usage.1),\"totalTokenCount\":\(usage.0 + usage.1)}" }
    return body + "}"
}

func makeClient(_ transport: FakeTransport, clock: TestClock = TestClock(), attempts: Int = 3) -> LLMClient {
    let gateway = LLMGateway(
        transport: transport,
        backoffPolicy: BackoffPolicy(initialDelay: 0.01, maxDelay: 0.05, maxAttempts: attempts),
        clock: clock
    )
    return LLMClient(config: Configuration(apiKey: "test-key", model: "m", projectRoot: URL(fileURLWithPath: "/tmp")),
                     gateway: gateway)
}

let validProposalJSON = """
{"type":"action_proposal","scenarioID":"SCENARIO-LANG-SHEET","snapshotID":"snap_1","elementID":"elem_29","expectedRole":"button","expectedIdentifier":"change-language-dropdown-button","toolName":"tap_element","arguments":{},"reason":"open"}
"""


extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

