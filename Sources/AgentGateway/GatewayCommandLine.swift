import Foundation
import AgentCore

/// The command line front-end over the same tools the MCP server offers: `tool list`, `tool describe <name>`, `tool call <name> [json]`.
/// Results are JSON on standard output (what a script or an agent without MCP can parse); anything for a person goes to standard error.
public enum GatewayCommandLine {
    public static let usage = """
    Usage:
      AutonomousTestingAgent tool list [--json|--markdown]     the tools and what they do
      AutonomousTestingAgent tool describe <name>               one tool with its JSON schema
      AutonomousTestingAgent tool call <name> ['{"arg":1}']     run a tool; arguments are JSON (or read from standard input with -)
    Options: --project-root=<dir> (default $ATA_PROJECT_ROOT or the current directory)
    Exit status: 0 the tool ran, 1 the tool returned an error, 2 bad usage.

    """

    /// Runs one `tool` command; returns the exit status. `arguments` are those after the word `tool`.
    public static func run(arguments: [String], gateway: Gateway? = nil, output: @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }) async -> Int32 {
        var rest = arguments
        let rootFlag = rest.firstIndex { $0.hasPrefix("--project-root=") }.map { rest.remove(at: $0) }
        let root = rootFlag.map { String($0.dropFirst("--project-root=".count)) } ?? ProcessInfo.processInfo.environment["ATA_PROJECT_ROOT"] ?? FileManager.default.currentDirectoryPath
        let projectRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL
        guard let command = rest.first else { return fail(usage) }
        let gateway = gateway ?? Gateway.live(projectRoot: projectRoot)
        switch command {
        case "list":
            if rest.contains("--markdown") { output(markdown(gateway)); return 0 }
            if rest.contains("--json") { output(json(gateway.tools.map { ["name": $0.name, "description": $0.description, "readOnly": $0.readOnly] })); return 0 }
            for tool in gateway.tools { output("\(tool.name)\(tool.readOnly ? "  (read-only)" : "")\n    \(tool.description.split(separator: "\n").first ?? "")") }
            return 0
        case "describe":
            guard rest.count >= 2, let tool = gateway.tool(named: rest[1]) else { return fail("No such tool. Run `tool list`.") }
            output(json(["name": tool.name, "description": tool.description, "readOnly": tool.readOnly, "inputSchema": foundation(tool.inputSchema)]))
            return 0
        case "call":
            guard rest.count >= 2 else { return fail(usage) }
            let text = rest.count >= 3 ? (rest[2] == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : rest[2]) : "{}"
            guard let data = text.data(using: .utf8), let arguments = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) else {
                return fail("The arguments must be a JSON object, for example '{\"command\":\"read_screen\"}'.")
            }
            let result = await gateway.call(rest[1], arguments: arguments, progress: { message, _ in FileHandle.standardError.write(Data((message + "\n").utf8)) })
            output(json(["isError": result.isError, "content": result.content.map { part -> [String: Any] in
                switch part {
                case .text(let text): ["type": "text", "text": text]
                case .image(let base64, let mime): ["type": "image", "mimeType": mime, "data": base64]
                }
            }]))
            return result.isError ? 1 : 0
        default:
            return fail(usage)
        }
    }

    /// The tool reference as Markdown: what the skill's `references/tools.md` is generated from.
    public static func markdown(_ gateway: Gateway) -> String {
        var lines = ["# Tools", "", "Generated from the tool catalogue (`AutonomousTestingAgent tool list --markdown`). Do not edit by hand.", ""]
        for tool in gateway.tools {
            lines.append("## \(tool.name)\(tool.readOnly ? " (read-only)" : "")")
            lines.append("")
            lines.append(tool.description)
            if case .dictionary(let schema) = tool.inputSchema, case .dictionary(let props)? = schema["properties"], !props.isEmpty {
                let required: Set<String> = { if case .array(let items)? = schema["required"] { Set(items.compactMap { if case .string(let name) = $0 { name } else { nil } }) } else { [] } }()
                lines.append("")
                lines.append("| Argument | Required | What |")
                lines.append("|---|---|---|")
                for name in props.keys.sorted() {
                    guard case .dictionary(let field) = props[name]!, case .string(let help)? = field["description"] else { continue }
                    lines.append("| `\(name)` | \(required.contains(name) ? "yes" : "no") | \(help.replacingOccurrences(of: "|", with: "/")) |")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }

    private static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func foundation(_ value: AnyCodableValue) -> Any {
        switch value {
        case .string(let text): text
        case .int(let number): number
        case .double(let number): number
        case .bool(let flag): flag
        case .null: NSNull()
        case .array(let items): items.map(foundation)
        case .dictionary(let fields): fields.mapValues(foundation)
        }
    }
}
