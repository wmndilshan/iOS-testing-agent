import Testing
import Foundation
@testable import AgentCore
@testable import AgentGateway
@testable import AgentMCP

/// Collects what the server sends, as parsed JSON.
private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    func add(_ data: Data) { if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { lock.withLock { messages.append(object) } } }
    var all: [[String: Any]] { lock.withLock { messages } }
    func reply(id: Int) -> [String: Any]? { all.first { ($0["id"] as? Int) == id } }
    func waitFor(id: Int) async -> [String: Any]? {
        for _ in 0..<200 { if let found = reply(id: id) { return found }; try? await Task.sleep(nanoseconds: 10_000_000) }
        return nil
    }
}

private func send(_ server: MCPServer, _ object: [String: Any]) async {
    await server.receive(try! JSONSerialization.data(withJSONObject: object))
}

private func makeServer(tools: [GatewayTool]? = nil) -> (MCPServer, Wire) {
    let wire = Wire()
    let gateway = Gateway(tools: tools ?? GatewayCatalogue.tools(GatewayServices(projectRoot: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)"), deviceControl: nil, launcher: nil)))
    return (MCPServer(gateway: gateway, info: MCPServerInfo(name: "test", version: "9", instructions: "how to use"), send: { wire.add($0) }), wire)
}

@Suite("MCP server")
struct MCPServerTests {
    @Test("initialize echoes a supported protocol version, offers tools only, and names itself")
    func initialize() async {
        let (server, wire) = makeServer()
        await send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "c", "version": "1"]]])
        let result = wire.reply(id: 1)?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2024-11-05")
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "test" && result?["instructions"] as? String == "how to use")
        let capabilities = result?["capabilities"] as? [String: Any]
        #expect(capabilities?["tools"] != nil && capabilities?["prompts"] != nil && capabilities?["resources"] == nil)
        await send(server, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect((wire.reply(id: 2)?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.supportedVersions[0], "an unknown version is answered with ours")
    }

    @Test("A notification gets no reply; ping and unknown methods are answered")
    func basics() async {
        let (server, wire) = makeServer()
        await send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        await send(server, ["jsonrpc": "2.0", "id": 3, "method": "ping"])
        await send(server, ["jsonrpc": "2.0", "id": 4, "method": "resources/list"])
        #expect(wire.all.count == 2, "only the two requests were answered")
        #expect(wire.reply(id: 3)?["result"] != nil)
        #expect(((wire.reply(id: 4)?["error"] as? [String: Any])?["code"] as? Int) == -32601)
    }

    @Test("A message that is not JSON gets a parse error with a null id")
    func parseError() async {
        let (server, wire) = makeServer()
        await server.receive(Data("not json".utf8))
        let error = wire.all.first?["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32700 && wire.all.first?["id"] is NSNull)
    }

    @Test("tools/list describes every tool with its schema and a read-only hint")
    func list() async throws {
        let (server, wire) = makeServer()
        await send(server, ["jsonrpc": "2.0", "id": 5, "method": "tools/list"])
        let tools = try #require((wire.reply(id: 5)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String ?? "" }.contains("device_input") && tools.count == 16)
        let observe = try #require(tools.first { $0["name"] as? String == "device_observe" })
        #expect((observe["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        #expect((observe["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        #expect((tools.first { $0["name"] as? String == "run_case" }?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false)
    }

    @Test("tools/call returns the tool's content; a tool's own failure is a result with isError, a missing name is a protocol error")
    func call() async {
        let (server, wire) = makeServer()
        await send(server, ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "list_cases", "arguments": [:]]])
        let ok = await wire.waitFor(id: 6)?["result"] as? [String: Any]
        let text = (ok?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(ok?["isError"] as? Bool == false && text?.contains("no test cases") == true)
        await send(server, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "device_observe", "arguments": ["command": "read_screen"]]])
        let failed = await wire.waitFor(id: 7)?["result"] as? [String: Any]
        #expect(failed?["isError"] as? Bool == true, "no device: an error the model can read")
        await send(server, ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": [:]])
        #expect(((wire.reply(id: 8)?["error"] as? [String: Any])?["code"] as? Int) == -32602)
        await send(server, ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "list_cases", "arguments": "nope"]])
        #expect(((wire.reply(id: 9)?["error"] as? [String: Any])?["code"] as? Int) == -32602)
        await send(server, ["jsonrpc": "2.0", "id": "abc", "method": "ping"])
        #expect(wire.all.contains { ($0["id"] as? String) == "abc" }, "a string id is echoed as a string")
    }

    @Test("Progress notifications carry the client's token; a cancelled call is never answered")
    func progressAndCancel() async {
        let slow = GatewayTool.testTool(name: "slow") { progress in
            progress("halfway", 0.5)
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .text("done")
        }
        let (server, wire) = makeServer(tools: [slow])
        await send(server, ["jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": ["name": "slow", "arguments": [:], "_meta": ["progressToken": "tok-1"]]])
        await send(server, ["jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": ["name": "slow", "arguments": [:]]])
        await send(server, ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 11]])
        #expect(await wire.waitFor(id: 10) != nil)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(wire.reply(id: 11) == nil, "cancelled")
        let progress = wire.all.first { ($0["method"] as? String) == "notifications/progress" }?["params"] as? [String: Any]
        #expect(progress?["progressToken"] as? String == "tok-1" && progress?["message"] as? String == "halfway" && progress?["progress"] as? Double == 0.5)
    }

    @Test("A ping is answered while a long call is still running")
    func pingDuringCall() async {
        let slow = GatewayTool.testTool(name: "slow") { _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return .text("done")
        }
        let (server, wire) = makeServer(tools: [slow])
        await send(server, ["jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": ["name": "slow", "arguments": [:]]])
        await send(server, ["jsonrpc": "2.0", "id": 13, "method": "ping"])
        #expect(wire.reply(id: 13) != nil && wire.reply(id: 12) == nil)
        #expect(await wire.waitFor(id: 12) != nil)
    }

    @Test("A picture goes out as an image content block")
    func image() async {
        let picture = GatewayTool.testTool(name: "pic") { _ in GatewayResult(content: [.image(base64: "QUJD", mimeType: "image/jpeg"), .text("caption")]) }
        let (server, wire) = makeServer(tools: [picture])
        await send(server, ["jsonrpc": "2.0", "id": 14, "method": "tools/call", "params": ["name": "pic"]])
        let parts = (await wire.waitFor(id: 14)?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(parts?.first?["type"] as? String == "image" && parts?.first?["mimeType"] as? String == "image/jpeg" && parts?.last?["text"] as? String == "caption")
    }
}

extension GatewayTool {
    /// A tool for protocol tests: runs `body` and takes no arguments.
    static func testTool(name: String, body: @escaping @Sendable (GatewayProgress) async -> GatewayResult) -> GatewayTool {
        GatewayTool(name: name, description: "test", properties: [:], readOnly: true) { _, progress in await body(progress) }
    }
}
