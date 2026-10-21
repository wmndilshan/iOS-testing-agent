import Foundation

/// Per-execution facts the executor stamps into results and logs. None of it grants authority.
struct IOSActionContext: Sendable {
    var toolName: String?
    var executionID: String?
    var bundleID: String = SimulatorTargetConfiguration.current.bundleID
    var association = ArtifactAssociation()
    var log = LogContext()
}

/// A performed action: the standardized result plus what the tool layer needs to build a `ToolResult`.
struct IOSActionExecution: Sendable {
    let result: IOSActionResult
    let output: IOSActionOutput
}

/// Executes a typed action against the driver port. Failures are logged with a neutral classification and
/// rethrown unchanged, so callers keep their typed `DriverError`s.
protocol IOSInteractionExecuting: Sendable {
    func execute(_ action: IOSAction, context: IOSActionContext) async throws -> IOSActionExecution
}

struct IOSInteractionExecutor: IOSInteractionExecuting {
    let driver: any DeviceDriver
    let artifactStore: (any ArtifactStoring)?
    let logger: any AppLogger
    let clock: any ClockProtocol

    func execute(_ action: IOSAction, context: IOSActionContext) async throws -> IOSActionExecution {
        let logContext = context.log.merged(with: LogContext(executionID: context.executionID, toolName: context.toolName))
        let started = clock.now()
        logger.info(.tool, "ios.action.started", context: logContext,
                    fields: ["actionType": .string(action.actionType), "mutating": .bool(action.isMutating)])

        let env = IOSExecutionEnvironment(driver: driver, artifactStore: artifactStore, association: context.association,
                                          bundleID: context.bundleID, clock: clock, logger: logger, context: logContext)
        var output: IOSActionOutput
        do {
            output = try await action.performer.perform(in: env)
        } catch {
            let kind = ActionFailureKind.of(error)
            logger.error(.tool, "ios.action.failed", context: logContext, fields: ["actionType": .string(action.actionType)],
                         duration: clock.now().timeIntervalSince(started), errorClass: kind.rawValue)
            throw error
        }

        let finished = clock.now()
        let success = output.status == .success
        let failure = success ? nil : ActionFailure(kind: .xctestFailure, message: SecretRedactor.redact(output.summary))
        let result = IOSActionResult(
            executionID: context.executionID, toolName: context.toolName, actionType: action.actionType,
            startedAt: started, finishedAt: finished, success: success, failure: failure,
            evidence: output.evidence, postObservationID: output.observation?.snapshotID, diagnostics: output.diagnostics)
        logger.log(success ? .info : .error, .tool, success ? "ios.action.completed" : "ios.action.failed", context: logContext,
                   fields: ["actionType": .string(action.actionType), "success": .bool(success), "evidenceCount": .int(output.evidence.count)],
                   duration: finished.timeIntervalSince(started), errorClass: failure?.kind.rawValue)
        return IOSActionExecution(result: result, output: output)
    }
}

extension IOSAction {
    /// The one place a typed action is mapped to its behavior. It grows by one line per capability and holds no logic.
    var performer: any IOSPerformable {
        switch self {
        case .tap(let a): return a
        case .doubleTap(let a): return a
        case .longPress(let a): return a
        case .swipe(let a): return a
        case .scroll(let a): return a
        case .drag(let a): return a
        case .typeText(let a): return a
        case .clearText(let a): return a
        case .waitForElement(let a): return a
        case .screenshot(let a): return a
        case .accessibilityTree(let a): return a
        case .appState(let a): return a
        case .elementDetails(let a): return a
        case .inspectElements(let a): return a
        case .keyPress(let a): return a
        case .dismissKeyboard(let a): return a
        case .dismissOverlay(let a): return a
        case .back(let a): return a
        case .selectTab(let a): return a
        case .selectPickerValue(let a): return a
        case .launchApp(let a): return a
        case .terminateApp(let a): return a
        case .activateApp(let a): return a
        }
    }
}
