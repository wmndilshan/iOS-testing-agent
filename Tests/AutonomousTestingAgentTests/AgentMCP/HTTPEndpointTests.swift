import Testing
import Foundation
@testable import AgentGateway
@testable import AgentMCP

@Suite("MCP over HTTP")
struct HTTPEndpointTests {
    private let endpoint = HTTPEndpoint(gateway: Gateway(tools: GatewayCatalogue.tools(GatewayServices(projectRoot: FileManager.default.temporaryDirectory.appendingPathComponent("http-\(UUID().uuidString)"), deviceControl: nil, launcher: nil))),
                                        info: MCPServerInfo(name: "t", version: "1", instructions: ""), token: "s3cret", timeout: 5)

    private func post(_ body: String, headers: [String: String] = ["authorization": "Bearer s3cret"], path: String = "/mcp", method: String = "POST") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    @Test("A request is parsed once its headers and whole body have arrived")
    func parser() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
        #expect(HTTPRequestParser.parse(Data(raw.utf8)) == .request(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "x", "content-length": "5"], body: Data("hello".utf8))))
        #expect(HTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Le".utf8)) == .needMore)
        #expect(HTTPRequestParser.parse(Data(String(raw.dropLast(2)).utf8)) == .needMore, "the body is not complete yet")
        #expect(HTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 9999999\r\n\r\n".utf8)) == .tooLarge)
        #expect(HTTPRequestParser.parse(Data("garbage\r\n\r\n".utf8)) == .malformed)
    }

    @Test("A call needs the bearer token, the /mcp path and a local origin; wrong ones are refused before anything runs")
    func refusals() async {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        #expect(await endpoint.handle(post(body, headers: [:])).status == 401)
        #expect(await endpoint.handle(post(body, headers: ["authorization": "Bearer nope"])).status == 401)
        #expect(await endpoint.handle(post(body, path: "/other")).status == 404)
        #expect(await endpoint.handle(post(body, headers: ["authorization": "Bearer s3cret", "origin": "https://evil.example"])).status == 403)
        #expect(await endpoint.handle(post(body, headers: ["authorization": "Bearer s3cret", "origin": "http://localhost:3000"])).status == 200)
        #expect(await endpoint.handle(post("", method: "GET")).status == 405)
        #expect(await endpoint.handle(post("not json")).status == 400)
    }

    @Test("A request gets its JSON-RPC reply in the body; a notification gets 202 and no body")
    func replies() async throws {
        let list = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#))
        let object = try #require(try JSONSerialization.jsonObject(with: list.body) as? [String: Any])
        #expect(list.status == 200 && object["id"] as? Int == 7 && ((object["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty == false)
        let note = await endpoint.handle(post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        #expect(note.status == 202 && note.body.isEmpty)
        let call = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"list_cases"}}"#))
        #expect((try JSONSerialization.jsonObject(with: call.body) as? [String: Any])?["id"] as? String == "a")
    }
}
