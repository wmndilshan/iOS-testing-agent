import Foundation
import AgentCore
import AgentInfrastructure
import AgentPresentation

/// The one place that wires the real adapters into the view-models the GUI shows. It only *constructs* collaborators and grants no authority:
/// every execution still traverses Proposal, validation, approval and authorization in the core.
public struct AppCompositionRoot: Sendable {
    public let infrastructure: InfrastructureFactory
    public var projectRoot: URL { infrastructure.projectRoot }

    public init(infrastructure: InfrastructureFactory) { self.infrastructure = infrastructure }

    /// Resolves the project root from configuration, falling back to the working directory.
    public static func fromEnvironment() -> AppCompositionRoot { AppCompositionRoot(infrastructure: .fromEnvironment()) }

    /// True when idb is installed, so the live view and device control can work.
    public var isIDBAvailable: Bool { IDBFramebufferSource.locate(projectRoot: projectRoot) != nil }

    /// True when a model key is set (Gemini or DeepSeek, in the environment or the project's `.env`): without one a case cannot be planned or judged.
    public var hasModelKey: Bool {
        let environment = ProcessInfo.processInfo.environment
        let file = Configuration.parseEnvFile(at: projectRoot.appendingPathComponent(".env")) ?? [:]
        let keys = ["LLM_API_KEY", "GEMINI_API_KEY", "DEEPSEEK_API_KEY"]
        return keys.contains { name in
            let value = (environment[name] ?? file[name] ?? "").trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && !Configuration.isPlaceholderKey(value)
        }
    }

    /// What the agents may do to the simulator, or nil without idb (also used by the developer harness).
    public func makeDeviceControl() -> (any DeviceControlling)? { infrastructure.makeDeviceControl() }

    /// Learned step skills (`.skills/steps`).
    public func makeStepSkillStore() -> StepSkillStore { infrastructure.makeStepSkillStore() }

    @MainActor
    public func makeSimulatorPaneModel() -> SimulatorPaneModel {
        let opener = WorkspaceSimulatorApplicationOpener()
        return SimulatorPaneModel(
            manager: infrastructure.makeSimulatorSessionManager(), framebuffer: infrastructure.makeFramebufferSource(),
            openRealSimulator: { opener.openSimulatorApplication() }
        )
    }

    /// The state behind the Cases tab: starts the runner as its own process and reads its events.
    @MainActor
    public func makeCaseRunState() -> CaseRunState {
        // The repository is read from the same saved setting as the chat's, when each run starts.
        let defaults = Self.agentDefaults()
        return CaseRunState(projectRoot: projectRoot, launcher: infrastructure.makeCommandLineLauncher(), repositoryPath: { defaults.string(forKey: AgentChatState.defaultsKey) ?? "" })
    }

    /// The Agent section's chat with the team of agents. The repository it reads is a setting the person chooses.
    @MainActor
    public func makeAgentChatState() -> AgentChatState {
        // A harness launch also keeps its conversations away from the person's own.
        let chats = Self.isAgentHarness() ? FileManager.default.temporaryDirectory.appendingPathComponent("AutonomousTestingAgent-harness-chats-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true) : nil
        return AgentChatState(projectRoot: projectRoot, launcher: infrastructure.makeCommandLineLauncher(), defaults: Self.agentDefaults(), conversationsDirectory: chats,
                              deviceControl: infrastructure.makeDeviceControl())
    }

    /// The Operate section: its own agent process and its own device handler (so its approvals and grants are separate from the chat's).
    @MainActor
    public func makeOperateState(library: TestLibraryState) -> OperateState {
        let defaults = Self.agentDefaults()
        let handler = DeviceRequestHandler(control: infrastructure.makeDeviceControl(), projectRoot: projectRoot)
        return OperateState(launcher: infrastructure.makeCommandLineLauncher(), handler: handler, library: library, defaults: defaults,
                            store: Self.isAgentHarness() ? nil : OperateSessionStore(directory: infrastructure.operateSessionsDirectory))
    }

    /// The History section's read-only view of past case runs, including those saved under the old folder name.
    @MainActor
    public func makeRunHistoryState() -> RunHistoryState {
        RunHistoryState(directory: infrastructure.caseRunsDirectory, legacyDirectory: infrastructure.legacyCaseRunsDirectory)
    }

    static func isAgentHarness(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains { $0.hasPrefix("--agent-replay") || $0.hasPrefix("--agent-scenario") || $0.hasPrefix("--agent-repo") || $0.hasPrefix("--operate-task") }
    }

    /// The person's saved chat settings and memory, except in a harness launch (`--agent-replay`, `--agent-scenario`, `--agent-repo`): those use
    /// a throw-away store, so a test launch can never change the repository or the memory the person relies on.
    static func agentDefaults(arguments: [String] = CommandLine.arguments) -> UserDefaults {
        guard isAgentHarness(arguments: arguments), let store = UserDefaults(suiteName: "AutonomousTestingAgent.harness") else { return .standard }
        store.removePersistentDomain(forName: "AutonomousTestingAgent.harness")
        return store
    }

}
