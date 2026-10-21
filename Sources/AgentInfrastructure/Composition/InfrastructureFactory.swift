import Foundation
import AgentCore

/// Where persistent state lives (`.runs/`, `.skills/`, `.artifacts/`, `.logs/`) and how the real adapters (idb, files, logging, simulator) are built.
/// The command line engine and the GUI's composition root both get their stores and drivers from here. It only *constructs* collaborators and grants
/// no authority: every execution still traverses proposal, validation, approval and authorization in the core.
public struct InfrastructureFactory: Sendable {
    public let projectRoot: URL
    public let simulatorTarget: SimulatorTarget

    public init(projectRoot: URL, simulatorTarget: SimulatorTarget = SimulatorTargetConfiguration.current) {
        self.projectRoot = projectRoot
        self.simulatorTarget = simulatorTarget
    }

    /// Resolves the project root from configuration, falling back to the working directory.
    public static func fromEnvironment() -> InfrastructureFactory {
        // Not `Configuration.load()`: that throws without a model key, and the project must not silently become the current folder then.
        let root = Configuration.resolveProjectRoot()
        return InfrastructureFactory(projectRoot: root)
    }

    /// The idb-backed driver for the simulator, or nil when idb is not installed. It observes and acts through idb.
    public func makeIDBDriver(simulatorUDID: String? = nil, isLiveExecutionEnabled: Bool = false) -> (any LiveExecutionControllable)? {
        let udid = simulatorUDID ?? simulatorTarget.udid
        guard let executable = IDBClient.locate(projectRoot: projectRoot) else { return nil }
        return IDBDriver(client: IDBClient(executable: executable, udid: udid), simulatorUDID: udid, isLiveExecutionEnabled: isLiveExecutionEnabled)
    }

    public var artifactsDirectory: URL { projectRoot.appendingPathComponent(".artifacts") }
    public var logsDirectory: URL { projectRoot.appendingPathComponent(".logs") }
    public var skillsDirectory: URL { projectRoot.appendingPathComponent(".skills") }
    public var runsDirectory: URL { projectRoot.appendingPathComponent(".runs") }
    /// Case run reports and their screenshots (`.runs/cases`). `.runs/aio` is the old name; it is still read, never written.
    public var caseRunsDirectory: URL { runsDirectory.appendingPathComponent("cases", isDirectory: true) }
    /// Saved Operate sessions (`.runs/operate`).
    public var operateSessionsDirectory: URL { runsDirectory.appendingPathComponent("operate", isDirectory: true) }
    public var legacyCaseRunsDirectory: URL { runsDirectory.appendingPathComponent("aio", isDirectory: true) }
    /// Learned step skills (`.skills/steps`). `.skills/aio` is the old name; it is still read, never written.
    public var stepSkillsDirectory: URL { skillsDirectory.appendingPathComponent("steps", isDirectory: true) }
    public var legacyStepSkillsDirectory: URL { skillsDirectory.appendingPathComponent("aio", isDirectory: true) }

    public func makeArtifactStore() -> FileArtifactStore { FileArtifactStore(directory: artifactsDirectory) }

    /// The application logger for a configuration. Off unless the configuration enables a destination,
    /// so default runs and tests write nothing.
    public func makeLogger(_ configuration: LogConfiguration = .load()) -> any AppLogger {
        LoggerFactory.make(configuration, fileURL: logsDirectory.appendingPathComponent("agent.log.jsonl"))
    }

    /// The single simulator session manager over `simctl`. Lifecycle only.
    public func makeSimulatorSessionManager() -> SimulatorSessionManager {
        SimulatorSessionManager(client: SimctlSimulatorClient())
    }

    /// Read-only framebuffer capture for the docked mirror (and the mirror CLI harness).
    public func makeFramebufferSource() -> any SimulatorFramebufferSource {
        // idb's video stream is the live source (about eight frames a second); simctl screenshots are the fallback without idb.
        IDBFramebufferSource.locate(projectRoot: projectRoot).map { IDBFramebufferSource(executable: $0) as any SimulatorFramebufferSource } ?? SimctlFramebufferCapture()
    }

    /// Learned step skills, kept in their own folder beside the scenario skills.
    public func makeStepSkillStore() -> StepSkillStore {
        StepSkillStore(directory: stepSkillsDirectory, legacyDirectory: legacyStepSkillsDirectory)
    }

    /// What the agents may do to the simulator (observe, tap, open links, grant permissions, and so on), or nil without idb. It is a lane of its
    /// own, separate from the trusted spine that runs test cases: the app executes each command after its approval policy has said yes.
    public func makeDeviceControl() -> (any DeviceControlling)? {
        guard let executable = IDBClient.locate(projectRoot: projectRoot) else { return nil }
        return IDBDeviceControl(executable: executable, preferredUDID: simulatorTarget.udid, questioner: GeminiScreenQuestioning())
    }

    /// The runner is built next to the app (`swift build` puts both in one folder).
    public func makeCommandLineLauncher() -> CaseRunProcessLauncher {
        let folder = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        return CaseRunProcessLauncher(executable: folder.appendingPathComponent("AutonomousTestingAgent"), workingDirectory: projectRoot)
    }

}
