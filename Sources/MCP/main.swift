import Foundation
import AgentGateway
import AgentMCP

// `ata-mcp`: the Autonomous Testing Agent as an MCP server over stdio. The project it works on is --project-root=<dir>, else ATA_PROJECT_ROOT, else
// the current directory. Protocol messages go to standard output; this tool writes only to standard error.
setvbuf(stdout, nil, _IONBF, 0)
let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--help") || arguments.contains("-h") {
    FileHandle.standardError.write(Data("""
    ata-mcp — Autonomous Testing Agent MCP server (stdio)
      --project-root=<dir>   project whose TestCases/ and .runs/ to use (default: $ATA_PROJECT_ROOT or the current directory)
      --http=<port>          serve MCP over HTTP at http://127.0.0.1:<port>/mcp instead of stdio (loopback only; needs a bearer token)
      --token=<secret>       the bearer token for --http (default: $ATA_MCP_TOKEN, else a new one is printed to standard error)
      --version              print the version and exit

    """.utf8))
    exit(0)
}
if arguments.contains("--version") {
    FileHandle.standardOutput.write(Data((MCPInfo.version + "\n").utf8))
    exit(0)
}
let root = arguments.first { $0.hasPrefix("--project-root=") }.map { String($0.dropFirst("--project-root=".count)) }
    ?? ProcessInfo.processInfo.environment["ATA_PROJECT_ROOT"] ?? FileManager.default.currentDirectoryPath
let projectRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL
FileHandle.standardError.write(Data("ata-mcp \(MCPInfo.version): project \(projectRoot.path)\n".utf8))
if let port = arguments.first(where: { $0.hasPrefix("--http=") }).flatMap({ UInt16($0.dropFirst("--http=".count)) }) {
    let given = arguments.first { $0.hasPrefix("--token=") }.map { String($0.dropFirst("--token=".count)) } ?? ProcessInfo.processInfo.environment["ATA_MCP_TOKEN"]
    let token = (given?.isEmpty == false ? given : nil) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    FileHandle.standardError.write(Data("ata-mcp: listening on http://127.0.0.1:\(port)/mcp\nata-mcp: send  Authorization: Bearer \(given == nil ? token : "<your token>")\n".utf8))
    do { try await HTTPTransport.run(endpoint: HTTPEndpoint(gateway: Gateway.live(projectRoot: projectRoot), info: MCPInfo.server, token: token), port: port) }
    catch { FileHandle.standardError.write(Data("ata-mcp: could not listen on port \(port): \(error.localizedDescription)\n".utf8)); exit(1) }
} else {
    await StdioTransport.run(gateway: Gateway.live(projectRoot: projectRoot), info: MCPInfo.server)
}
