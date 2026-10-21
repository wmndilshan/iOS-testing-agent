import Foundation

public final class ToolRegistry: Sendable {
    public let projectRoot: URL
    public let simulatorDestinationID: String
    private let driver: any DeviceDriver
    package var executionDriver: any DeviceDriver { driver }
    /// Runs every iOS capability as a typed action. The registry itself holds no gesture logic.
    private let iosTools: IOSToolAdapter

    /// Collaborators are injected: the composition root supplies the idb driver, tests supply a `SimulatedDriver`.
    ///
    /// - `artifactStore`: where screenshots are stored as artifacts. `nil` (tests, previews) keeps the driver's
    ///   file path in the result and writes nothing.
    public init(
        projectRoot: URL,
        simulatorDestinationID: String = SimulatorTargetConfiguration.current.udid,
        driver: any DeviceDriver,
        artifactStore: (any ArtifactStoring)? = nil,
        logger: any AppLogger = NullLogger(),
        clock: any ClockProtocol = SystemClock()
    ) {
        self.projectRoot = projectRoot
        self.simulatorDestinationID = simulatorDestinationID
        self.driver = driver
        self.iosTools = IOSToolAdapter(
            executor: IOSInteractionExecutor(driver: driver, artifactStore: artifactStore, logger: logger, clock: clock),
            logger: logger)
    }

    // MARK: - Tool Declarations

    // MARK: - Synchronous Project Info Helper

    public func getProjectInfo() -> ProjectInfo {
        let fm = FileManager.default
        let rootPath = projectRoot.path

        let packageSwiftURL = projectRoot.appendingPathComponent("Package.swift")
        let packageSwiftPresent = fm.fileExists(atPath: packageSwiftURL.path)

        var projectStructure: [String] = []
        if let rootContents = try? fm.contentsOfDirectory(atPath: rootPath) {
            for item in rootContents.sorted() {
                if item.hasPrefix(".") { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: projectRoot.appendingPathComponent(item).path, isDirectory: &isDir) {
                    projectStructure.append(isDir.boolValue ? "\(item)/" : item)
                }
            }
        }

        var sourceFiles: [String] = []
        let sourcesURL = projectRoot.appendingPathComponent("Sources")
        if let enumerator = fm.enumerator(at: sourcesURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "swift" {
                    let relativePath = fileURL.path.replacingOccurrences(of: rootPath + "/", with: "")
                    sourceFiles.append(relativePath)
                }
            }
        }
        sourceFiles.sort()

        let projectName = projectRoot.lastPathComponent.isEmpty ? "AutonomousTestingAgent" : projectRoot.lastPathComponent

        return ProjectInfo(
            projectName: projectName,
            packageSwiftPresent: packageSwiftPresent,
            sourceFiles: sourceFiles,
            projectStructure: projectStructure
        )
    }

    // MARK: - Async Typed Tool Execution

    /// Runs a tool that cannot change the app or simulator. The classification comes from the trusted
    /// `ToolCatalog`, never from the call: a mutating tool is refused here whatever its arguments say,
    /// and an unknown tool or an input that violates the tool's schema is refused too.
    public func executeReadOnly(
        toolCall: ToolCall,
        bundleID: String = SimulatorTargetConfiguration.current.bundleID,
        executionID: String? = nil,
        association: ArtifactAssociation = ArtifactAssociation(),
        forceLive: Bool = false
    ) async throws -> ToolResult {
        guard let descriptor = ToolCatalog.descriptor(for: toolCall.name) else {
            throw ToolRegistryError.toolNotFound(toolCall.name)
        }
        guard descriptor.risk == .readOnly else {
            throw ToolRegistryError.authorizationRequired(toolCall.name)
        }
        let priorMode = await (driver as? any LiveExecutionControllable)?.isLiveExecutionEnabled
        if forceLive, priorMode == false, let switchable = driver as? any LiveExecutionControllable {
            await switchable.setLiveExecution(enabled: true)
        }
        do {
            let result = try await run(try ToolResolver().resolve(toolCall),
                                       bundleID: bundleID, executionID: executionID, association: association)
            if forceLive, let priorMode, let switchable = driver as? any LiveExecutionControllable {
                await switchable.setLiveExecution(enabled: priorMode)
            }
            return result
        } catch {
            if forceLive, let priorMode, let switchable = driver as? any LiveExecutionControllable {
                await switchable.setLiveExecution(enabled: priorMode)
            }
            throw error
        }
    }

    /// Narrow mode-control port used by composition/presentation. The underlying driver is never
    /// exposed, and this operation cannot execute an action.
    public func setLiveExecution(enabled: Bool) async {
        if let switchable = driver as? any LiveExecutionControllable {
            await switchable.setLiveExecution(enabled: enabled)
        }
    }

    /// Runs an approved call. The proof can only be created by `DispatchAuthorizer` after the
    /// approval, TTL, tool, target and snapshot checks, and must cover exactly this tool and these
    /// arguments, so a model-produced call is never an authorization by itself.
    public func execute(
        _ toolCall: ToolCall,
        authorization: DispatchAuthorizer.Authorized,
        association: ArtifactAssociation = ArtifactAssociation()
    ) async throws -> ToolResult {
        guard authorization.toolName == toolCall.name, authorization.arguments == toolCall.arguments else {
            throw ToolRegistryError.authorizationMismatch(toolCall.name)
        }
        guard authorization.context.simulatorUDID == simulatorDestinationID else {
            throw ToolRegistryError.authorizationMismatch(toolCall.name)
        }
        return try await run(try ToolResolver().resolve(toolCall),
                             bundleID: authorization.context.bundleID,
                             executionID: authorization.context.executionID, association: association)
    }

    /// Runs a resolved call and stamps the result with the tool, execution ID, duration and, when it
    /// did not succeed, a neutral failure classification.
    private func run(_ resolved: ToolResolver.Resolved, bundleID: String, executionID: String?,
                     association: ArtifactAssociation) async throws -> ToolResult {
        let started = Date()
        var result = try await perform(resolved.call, descriptor: resolved.descriptor,
                                       bundleID: bundleID, executionID: executionID, association: association)
        result.toolName = resolved.descriptor.name
        result.executionID = executionID
        result.durationSeconds = Date().timeIntervalSince(started)
        if result.status != .success, result.failure == nil {
            let category: ErrorCategory = result.status == .timedOut ? .timeout : (result.status == .rejected ? .validation : .execution)
            result.failure = ToolFailure(
                category: category,
                retryable: resolved.descriptor.risk == .readOnly && result.status == .timedOut,
                message: SecretRedactor.redact(result.summary)
            )
        }
        return result
    }

    private func perform(_ toolCall: ToolCall, descriptor: ToolDescriptor, bundleID: String,
                         executionID: String?, association: ArtifactAssociation) async throws -> ToolResult {
        // Host tools are answered here; every iOS capability is a typed action run by the interaction executor.
        guard descriptor.platform == .ios else {
            guard toolCall.name == "get_project_info" else { throw ToolRegistryError.toolNotFound(toolCall.name) }
            let info = getProjectInfo()
            return ToolResult(callID: toolCall.id, status: .success,
                              summary: "Retrieved project info for \(info.projectName).", payload: info.toDictionary())
        }
        return try await iosTools.execute(
            ToolResolver.Resolved(descriptor: descriptor, call: toolCall),
            context: IOSActionContext(toolName: descriptor.name, executionID: executionID, bundleID: bundleID,
                                      association: association, log: LogContext(scenarioID: association.scenarioID, stepID: association.stepID))
        )
    }
}
