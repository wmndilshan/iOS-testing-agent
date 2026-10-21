import Foundation
import AgentEngine
import AgentGateway

// The command line tool is a thin shell: `tool …` goes to the gateway (the same tools the MCP server offers), everything else to the engine.
let arguments = CommandLine.arguments
if arguments.dropFirst().first == "tool" {
    exit(await GatewayCommandLine.run(arguments: Array(arguments.dropFirst(2))))
}
await Engine.run(arguments: arguments)
