import Foundation
import AgentCore
import AgentInfrastructure
import TestCaseSources

/// The tool layer: every tool another agent may call, behind one `call`. It knows nothing about MCP or the command line; those are front-ends.
public final class Gateway: Sendable {
    public let tools: [GatewayTool]
    /// Cases and run reports a client can read without a tool call. Nil for a gateway that offers tools only.
    public let resources: GatewayResources?

    public init(tools: [GatewayTool], resources: GatewayResources? = nil) {
        self.tools = tools
        self.resources = resources
    }

    public func tool(named name: String) -> GatewayTool? { tools.first { $0.name == name } }

    /// Runs a tool. An unknown name or a bad argument comes back as an error result, so the calling agent can read it and correct itself.
    public func call(_ name: String, arguments: [String: AnyCodableValue], progress: @escaping GatewayProgress = { _, _ in }) async -> GatewayResult {
        guard let tool = tool(named: name) else {
            return .error("There is no tool named “\(name)”. The tools are: \(tools.map(\.name).joined(separator: ", ")).")
        }
        let result = await tool.run(arguments, progress)
        // Nothing a tool prints may carry a secret out to the calling agent.
        return GatewayResult(content: result.content.map { part in
            if case .text(let text) = part { .text(SecretRedactor.redact(text)) } else { part }
        }, isError: result.isError)
    }

    /// The real gateway: idb device control, the project's cases and run reports, and the command line tool for runs and planning.
    public static func live(projectRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> Gateway {
        let factory = InfrastructureFactory(projectRoot: projectRoot)
        // Login details may live in the project's git-ignored .env as well as in the real environment; the real environment wins.
        var merged = environment
        let file = Configuration.parseEnvFile(at: projectRoot.appendingPathComponent(".env")) ?? [:]
        for key in ["TEST_USER_USERNAME", "TEST_USER_PASSWORD"] where (merged[key] ?? "").isEmpty { if let value = file[key], !value.isEmpty { merged[key] = value } }
        let services = GatewayServices(projectRoot: projectRoot, deviceControl: factory.makeDeviceControl(), launcher: factory.makeCommandLineLauncher(),
                                       environment: merged)
        return Gateway(tools: GatewayCatalogue.tools(services), resources: GatewayResources(services))
    }
}

/// What the tools need from the outside, passed in so tests can replace each part.
public struct GatewayServices: Sendable {
    public let projectRoot: URL
    public let deviceControl: (any DeviceControlling)?
    public let launcher: (any CaseRunLaunching)?
    public let environment: [String: String]

    public init(projectRoot: URL, deviceControl: (any DeviceControlling)?, launcher: (any CaseRunLaunching)?, environment: [String: String] = [:]) {
        self.projectRoot = projectRoot
        self.deviceControl = deviceControl
        self.launcher = launcher
        self.environment = environment
    }

    var casesDirectory: URL { projectRoot.appendingPathComponent("TestCases", isDirectory: true) }
    /// Cases fetched from AIO and cached by the runner.
    var cachedCasesDirectory: URL { projectRoot.appendingPathComponent("Scripts/AIO/generated", isDirectory: true) }
    var caseRunsDirectory: URL { projectRoot.appendingPathComponent(".runs/cases", isDirectory: true) }
}

/// The list of tools, in the order a client sees them.
public enum GatewayCatalogue {
    public static func tools(_ services: GatewayServices) -> [GatewayTool] {
        DeviceGatewayTools.tools(services) + CaseGatewayTools.tools(services) + [PlanGatewayTool.tool(services)]
    }
}
