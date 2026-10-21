import Testing
import Foundation
@testable import AgentCore
@testable import AgentGateway

private final class Out: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

@Suite("Gateway command line")
struct GatewayCommandLineTests {
    private func gateway() -> Gateway {
        Gateway(tools: [
            GatewayTool(name: "echo", description: "Echo a word.", properties: ["word": Schema.string("The word")], required: ["word"], readOnly: true) { args, _ in
                args.string("word").map { .text($0) } ?? .error("word is required")
            },
        ])
    }

    private func run(_ arguments: [String]) async -> (Int32, String) {
        let out = Out()
        let status = await GatewayCommandLine.run(arguments: arguments + ["--project-root=/tmp"], gateway: gateway(), output: { out.add($0) })
        return (status, out.text)
    }

    @Test("list, in plain text, as JSON and as Markdown")
    func list() async {
        let plain = await run(["list"])
        #expect(plain.0 == 0 && plain.1.contains("echo  (read-only)") && plain.1.contains("Echo a word."))
        let json = await run(["list", "--json"])
        #expect(json.1.contains("\"name\" : \"echo\"") || json.1.contains("\"name\":\"echo\""))
        let markdown = await run(["list", "--markdown"])
        #expect(markdown.1.contains("## echo (read-only)") && markdown.1.contains("| `word` | yes | The word |"))
    }

    @Test("describe prints the schema; an unknown tool is a usage error")
    func describe() async {
        let found = await run(["describe", "echo"])
        #expect(found.0 == 0 && found.1.contains("inputSchema") && found.1.contains("\"required\""))
        #expect((await run(["describe", "nope"])).0 == 2)
    }

    @Test("call runs the tool with JSON arguments and exits 1 when the tool reports an error")
    func call() async {
        let ok = await run(["call", "echo", "{\"word\":\"hi\"}"])
        #expect(ok.0 == 0 && ok.1.contains("\"text\" : \"hi\"") && ok.1.contains("\"isError\" : false"))
        let failed = await run(["call", "echo", "{}"])
        #expect(failed.0 == 1 && failed.1.contains("\"isError\" : true"))
        #expect((await run(["call", "echo", "not json"])).0 == 2)
        #expect((await run(["call"])).0 == 2)
        #expect((await run([])).0 == 2)
    }
}
