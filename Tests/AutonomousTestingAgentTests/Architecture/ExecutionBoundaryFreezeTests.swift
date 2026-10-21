import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Freezes the trusted runtime boundaries. A change to any allow-list below is a deliberate
/// architecture change and must be reflected in `ARCHITECTURE.md`.
@Suite("Execution boundary freeze")
struct ExecutionBoundaryFreezeTests {

    @Test func testProcessesAreLaunchedOnlyFromTheKnownSites() {
        let allowed: Set<String> = [
            "SimctlSimulatorClient.swift",   // human-driven device list / boot / shutdown (not agent reachable)
            "SimctlFramebufferCapture.swift", // read-only `simctl io screenshot` for the mirror, behind SimulatorFramebufferSource
            "GitCommandRunner.swift",        // read-only git (rev-parse/diff/show/ls-files) for the test planner; not agent reachable
            "CaseRunProcess.swift",          // starts the test runner command line for the Cases tab, behind CaseRunLaunching
            "IDBFramebufferSource.swift",    // read-only `idb video-stream` for the live view, behind SimulatorFramebufferSource
            "IDBClient.swift"                // the `idb` CLI behind IDBDriver (array arguments, no shell, time-limited); reached only through the driver port
        ]
        let launching = Set(SourceTree.all.filter { $0.symbols.contains("Process()") }.map(\.name))
        #expect(launching == allowed, "unexpected process launch sites: \(launching.symmetricDifference(allowed).sorted())")
    }

    @Test func testDeviceLifecycleIsNeverReachableFromTheAgentPath() {
        let banned = ["SimulatorSessionManager", "SimulatorManaging", "SimctlSimulatorClient"]
        for file in SourceTree.core where ["Orchestration", "Tools", "LLM", "Security", "Domain", "Recovery"].contains(where: { file.inLayer($0) }) {
            for name in banned { #expect(!file.symbols.contains(name), "\(file.path) must not reach device lifecycle (\(name))") }
        }
    }

    @Test func testOnlyTheDispatcherExecutesMutatingTools() {
        for file in SourceTree.all where !file.isDispatcher && !file.name.hasPrefix("ToolRegistry") {
            #expect(!file.symbols.contains("toolRegistry.execute(") && !file.symbols.contains("registry.execute("), "\(file.path)")
        }
    }

    @Test func testAutomaticApprovalExistsOnlyInTheLabeledNonHumanModes() {
        let sup = SourceTree.all.first { $0.name == "Engine+SupervisorApproval.swift" }!.code
        // The human branch reads stdin (through the process's one stdin reader, with a timeout, which treats no answer as a denial);
        // the scripted branch is reachable only for the non-human modes.
        #expect(sup.contains("case .liveHumanApproval:") && sup.contains("StdinAnswers.shared.next("))
        let events = SourceTree.all.first { $0.name == "CaseRunEvents.swift" }!.code
        #expect(events.contains("readLine(strippingNewline: true)"), "the one stdin reader reads the real stdin")
        #expect(sup.contains("case .nonLiveTest, .liveAutonomousAfterLogin:") && sup.contains("NOT a human supervisor"))
        let mode = SourceTree.all.first { $0.name == "CLIExecutionMode.swift" }!.code
        #expect(mode.contains("var isLive: Bool { self == .liveHumanApproval || self == .liveAutonomousAfterLogin }"),
                "only genuine human approval and the delegated AIO mode may select live mutation")
        #expect(mode.contains("var isGenuineHumanApproval: Bool { self == .liveHumanApproval }"), "the delegated mode never claims human approval")
        // The delegated mode is reachable only through the AIO runner; every other entry point rejects it or never names it.
        let naming = Set(SourceTree.all.filter { $0.code.contains("liveAutonomousAfterLogin") }.map(\.name))
        #expect(naming == ["CLIExecutionMode.swift", "Engine+SupervisorApproval.swift", "CaseRunner.swift"], "\(naming)")
        // The case runner is the only entry point that takes a mode; the delegated mode is rejected unless it is chosen explicitly there.
        let runner = SourceTree.all.first { $0.name == "CaseRunner.swift" }!.code
        #expect(runner.contains("mode == .liveAutonomousAfterLogin || mode == .nonLiveTest"))
    }

    @Test func testMutatingToolsAreNeverRetriedAutomatically() {
        for file in SourceTree.core where file.inLayer("Orchestration") || file.inLayer("Tools") {
            #expect(!file.symbols.contains("retryMutating") && !file.symbols.contains("autoRetry"), "\(file.path)")
        }
        let registry = SourceTree.core.first { $0.name == "ToolRegistry.swift" }!.code
        #expect(registry.contains("retryable: resolved.descriptor.risk == .readOnly"), "only read-only tools are ever marked retryable")
    }
}
