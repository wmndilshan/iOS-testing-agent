import Testing
import Foundation

/// The gateway is the one door other agents use. These pin what it may and may not do, so a new tool cannot quietly widen it.
@Suite("Gateway architecture")
struct GatewayArchitectureTests {
    private var gateway: [SourceTree.File] { SourceTree.all.filter { $0.module == "AgentGateway" } }
    private var mcp: [SourceTree.File] { SourceTree.all.filter { $0.module == "AgentMCP" || $0.module == "MCP" } }

    @Test("The gateway starts no process itself and has no shell: runs go through the launcher port")
    func noProcesses() {
        #expect(!gateway.isEmpty)
        for file in gateway {
            for banned in ["Process()", "NSTask", "/bin/sh", "/bin/zsh", "sh -c", "posix_spawn", "system("] { #expect(!file.symbols.contains(banned) && !file.code.contains(banned), "\(file.path) uses \(banned)") }
        }
    }

    @Test("The protocol layer and the server executable name no adapter, no driver and no view-model")
    func protocolIsPure() {
        #expect(!mcp.isEmpty)
        for file in mcp {
            for banned in ["IDBClient", "IDBDriver", "IDBDeviceControl", "DeviceControlPolicy", "InfrastructureFactory", "AgentChatState", "OperateState"] {
                #expect(!file.symbols.contains(banned), "\(file.path) names \(banned)")
            }
        }
    }

    @Test("The gateway reaches the device only through the shared pipeline, and the destructive rule is in the device tools")
    func devicePath() {
        let device = gateway.first { $0.name == "DeviceGatewayTools.swift" }!
        #expect(device.code.contains("DeviceCommandPipeline") && device.code.contains("prepare(") && device.code.contains("confirm"))
        #expect(device.code.contains("prepared.risk == .destructive"))
        for file in gateway where file.name != "DeviceGatewayTools.swift" { #expect(!file.symbols.contains("DeviceControlling.run") && !file.code.contains("control.run("), "\(file.path)") }
    }

    @Test("Passwords are read only from the server's environment and are never a tool argument")
    func noPasswordArguments() {
        let cases = gateway.first { $0.name == "CaseGatewayTools.swift" }!
        #expect(!cases.code.contains("Schema.string(\"Password") && !cases.code.contains("args.string(\"password\")"))
        let monitor = gateway.first { $0.name == "RunMonitor.swift" }!
        #expect(monitor.code.contains("environment[\"TEST_USER_PASSWORD\"]"))
    }

    @Test("Every tool's text passes through the secret redactor before it leaves")
    func redacted() {
        let core = gateway.first { $0.name == "Gateway.swift" }!
        #expect(core.code.contains("SecretRedactor.redact"))
    }
}
