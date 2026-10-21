import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// The device-control lane is separate from the trusted spine that runs test cases. These pin what keeps it safe: typed commands only, one place
/// that starts processes, no path into the spine, and no way for the agent process to reach the device or approve for itself.
@Suite("Device control lane")
struct DeviceControlLaneTests {
    private var lane: [SourceTree.File] { SourceTree.core.filter { $0.path.contains("/DeviceControl/") } }
    private var agentFiles: [SourceTree.File] { SourceTree.all.filter { $0.path.hasPrefix("Sources/AgentEngine/Agents/") } }

    @Test("The lane has files in all three layers")
    func exists() {
        for layer in ["Domain", "Application", "Infrastructure"] { #expect(lane.contains { $0.layer == layer }, Comment(rawValue: layer)) }
    }

    @Test("No process is started by the lane: commands reach idb and simctl only through IDBClient")
    func noProcesses() {
        for file in lane { #expect(!file.symbols.contains("Process()") && !file.symbols.contains("NSTask"), "\(file.path)") }
        let client = SourceTree.all.first { $0.name == "IDBClient.swift" }!
        #expect(client.symbols.contains("Process()"))
    }

    @Test("The lane never touches the trusted spine: no registry, dispatcher, authorizer, approval policy or controller")
    func notTheSpine() {
        let banned = ["ToolRegistry", "ScenarioStepDispatcher", "DispatchAuthorizer", "ApprovalPolicy", "ScenarioExecutionController", "ProposalAdmission", "TrustedActionValidator"]
        for file in lane { for name in banned { #expect(!file.symbols.contains(name), "\(file.path) names \(name)") } }
    }

    @Test("The pure layers hold no I/O: no Foundation process, network or file-write calls in Domain and Application")
    func pure() {
        for file in lane where file.path.contains("/Domain/") || file.path.contains("/Application/") {
            for banned in ["URLSession", "FileManager.default.createFile", ".write(to:", "removeItem"] { #expect(!file.symbols.contains(banned), "\(file.path) uses \(banned)") }
        }
    }

    @Test("The agent process cannot reach the device or apply an approval: it never names the executor, idb or the policy")
    func agentIsOnlyARequester() {
        for file in agentFiles {
            for name in ["DeviceControlling", "IDBClient", "IDBDeviceControl", "DeviceControlPolicy", "DeviceGrants", "IDBCommandBuilder"] {
                #expect(!file.symbols.contains(name), "\(file.path) names \(name)")
            }
        }
    }

    @Test("Only the app's chat state executes device commands, and the presentation layer never names idb")
    func appIsTheExecutor() {
        let callers = SourceTree.all.filter { $0.symbols.contains("control.run(") || $0.symbols.contains("deviceControl.run(") }
        // The one other caller is the developer harness flag `--device-run`, compiled only into debug builds (it skips the approval on purpose).
        #expect(callers.map(\.name) == ["DeviceCommandPipeline.swift", "LaunchHarness.swift"], "\(callers.map(\.name))")
        let harness = callers.first { $0.name == "LaunchHarness.swift" }
        #expect(harness.map { $0.text.contains("#if DEBUG") && $0.text.contains("--device-run") } == true)
        for file in SourceTree.core where file.inLayer("Presentation") { #expect(!file.symbols.contains("IDBClient") && !file.symbols.contains("Process()"), "\(file.path)") }
    }

    @Test("No generic command runner: no catalog argument or string takes a command line")
    func noRunner() {
        for file in lane { for banned in ["/bin/sh", "/bin/zsh", "/bin/bash", "sh -c", "launchPath"] { #expect(!file.text.contains(banned), "\(file.path) contains \(banned)") } }
    }
}
