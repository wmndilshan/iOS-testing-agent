import Testing
import Foundation
@testable import AgentCore
@testable import AgentGateway
@testable import AgentMCP

private func project() throws -> (root: URL, services: GatewayServices) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("junit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("TestCases"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".runs/cases"), withIntermediateDirectories: true)
    return (root, GatewayServices(projectRoot: root, deviceControl: nil, launcher: nil))
}

private func report(key: String = "SAFARI-1") -> CaseRunReport {
    var report = CaseRunReport(testKey: key, title: "Open <a> page & share", mode: "LIVE", steps: [
        .init(id: "1.a", sourceStepNumber: 1, intent: "Launch", action: "launch", status: .passed),
        .init(id: "2.a", sourceStepNumber: 2, intent: "Tap \"Share\"", action: "tap", status: .failed, detail: "no button <Share> \u{1}found"),
        .init(id: "3.a", sourceStepNumber: 3, intent: "Pick Reminders", action: "tap", status: .skipped, detail: "not reached"),
    ])
    report.closeOut(outcome: "FAILED")
    return report
}

private func save(_ report: CaseRunReport, id: String, in root: URL) throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(report).write(to: root.appendingPathComponent(".runs/cases/\(id).json"))
}

@Suite("JUnit export and resources")
struct JUnitAndResourcesTests {
    @Test("A run becomes one testsuite with a testcase per step: failure, skipped and passing, escaped and valid XML")
    func junit() throws {
        let xml = JUnitReport.xml([("SAFARI-1-a", report())])
        #expect(xml.contains("tests=\"3\" failures=\"1\" errors=\"0\" skipped=\"1\""))
        #expect(xml.contains("<failure message=\"no button &lt;Share&gt; found\">"), "reserved and control characters are handled")
        #expect(xml.contains("name=\"Step 2: Tap &quot;Share&quot;\""))
        #expect(xml.contains("<skipped message=\"not reached\"/>"))
        // A real XML parser accepts it.
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "\(parser.parserError?.localizedDescription ?? "")")
    }

    @Test("get_report format=junit covers the latest run of each case; one id gives that run")
    func tool() async throws {
        let (root, services) = try project()
        var older = report(); older.closeOut(outcome: "PASSED")
        try save(older, id: "SAFARI-1-old", in: root)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try save(report(), id: "SAFARI-1-new", in: root)
        try save(report(key: "NME-1"), id: "NME-1-a", in: root)
        let gateway = Gateway(tools: GatewayCatalogue.tools(services))
        let all = await gateway.call("get_report", arguments: ["format": .string("junit")])
        #expect(!all.isError && all.plainText.components(separatedBy: "<testsuite ").count - 1 == 2)
        let one = await gateway.call("get_report", arguments: ["format": .string("junit"), "run_id": .string("NME-1-a")])
        #expect(one.plainText.contains("name=\"NME-1\"") && !one.plainText.contains("SAFARI-1"))
        let text = await gateway.call("get_report", arguments: ["run_id": .string("NME-1-a")])
        #expect(text.plainText.hasPrefix("NME-1-a: NME-1"))
        let bad = await gateway.call("get_report", arguments: ["run_id": .string("../x")])
        #expect(bad.isError)
    }

    @Test("Resources list the cases and runs, read them, and refuse anything else")
    func resources() throws {
        let (root, services) = try project()
        try Data(#"{"key":"SAFARI-1","title":"T","source":"files","steps":[]}"#.utf8).write(to: root.appendingPathComponent("TestCases/SAFARI-1.json"))
        try save(report(), id: "SAFARI-1-a", in: root)
        let resources = GatewayResources(services)
        let uris = resources.list().map(\.uri)
        #expect(uris.contains("ata://case/SAFARI-1") && uris.contains("ata://run/SAFARI-1-a") && uris.contains("ata://run/SAFARI-1-a/junit"))
        #expect(resources.read(uri: "ata://case/SAFARI-1")?.text.contains("SAFARI-1") == true)
        #expect(resources.read(uri: "ata://run/SAFARI-1-a")?.mimeType == "text/plain")
        #expect(resources.read(uri: "ata://run/SAFARI-1-a/junit")?.text.contains("<testsuite") == true)
        #expect(resources.read(uri: "ata://case/..%2F..%2F.env") == nil)
        #expect(resources.read(uri: "ata://case/missing") == nil)
        #expect(resources.read(uri: "file:///etc/passwd") == nil)
    }

    @Test("The MCP server advertises resources only when the gateway has them, and serves list and read")
    func mcp() async throws {
        let (root, services) = try project()
        try Data(#"{"key":"SAFARI-1","title":"T","source":"files","steps":[]}"#.utf8).write(to: root.appendingPathComponent("TestCases/SAFARI-1.json"))
        final class Box: @unchecked Sendable { var messages: [[String: Any]] = []; let lock = NSLock() }
        let box = Box()
        let server = MCPServer(gateway: Gateway(tools: [], resources: GatewayResources(services)), info: MCPServerInfo(name: "t", version: "1", instructions: ""),
                               send: { data in if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { box.lock.withLock { box.messages.append(o) } } })
        func ask(_ id: Int, _ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
            await server.receive(try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]))
            return box.lock.withLock { box.messages.first { ($0["id"] as? Int) == id } }
        }
        let initialized = (await ask(1, "initialize", ["protocolVersion": "2025-06-18"]))?["result"] as? [String: Any]
        #expect((initialized?["capabilities"] as? [String: Any])?["resources"] != nil)
        let list = ((await ask(2, "resources/list"))?["result"] as? [String: Any])?["resources"] as? [[String: Any]]
        #expect(list?.first?["uri"] as? String == "ata://case/SAFARI-1")
        let read = ((await ask(3, "resources/read", ["uri": "ata://case/SAFARI-1"]))?["result"] as? [String: Any])?["contents"] as? [[String: Any]]
        #expect((read?.first?["text"] as? String)?.contains("SAFARI-1") == true)
        let missing = (await ask(4, "resources/read", ["uri": "ata://case/NOPE"]))?["error"] as? [String: Any]
        #expect(missing?["code"] as? Int == -32002)
    }
}

@Suite("MCP prompts")
struct PromptTests {
    @Test("prompts/list names the prompts; prompts/get renders one with its arguments and refuses a missing required one")
    func prompts() async {
        final class Box: @unchecked Sendable { var messages: [[String: Any]] = []; let lock = NSLock() }
        let box = Box()
        let server = MCPServer(gateway: Gateway(tools: []), info: MCPServerInfo(name: "t", version: "1", instructions: ""),
                               send: { data in if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { box.lock.withLock { box.messages.append(o) } } })
        func ask(_ id: Int, _ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
            await server.receive(try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]))
            return box.lock.withLock { box.messages.first { ($0["id"] as? Int) == id } }
        }
        let list = ((await ask(1, "prompts/list"))?["result"] as? [String: Any])?["prompts"] as? [[String: Any]]
        #expect(list?.compactMap { $0["name"] as? String } == ["write_case", "triage_failure", "plan_for_diff"])
        let got = (await ask(2, "prompts/get", ["name": "write_case", "arguments": ["feature": "share to Reminders"]]))?["result"] as? [String: Any]
        let message = ((got?["messages"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["text"] as? String
        #expect(message?.contains("share to Reminders") == true && message?.contains("write_case") == true)
        #expect(((await ask(3, "prompts/get", ["name": "write_case"]))?["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(((await ask(4, "prompts/get", ["name": "nope"]))?["error"] as? [String: Any])?["code"] as? Int == -32602)
        let triage = (await ask(5, "prompts/get", ["name": "triage_failure"]))?["result"] as? [String: Any]
        #expect(triage != nil, "an optional argument may be left out")
    }
}
