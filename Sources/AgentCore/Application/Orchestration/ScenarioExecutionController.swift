import Foundation

// MARK: - ScenarioExecutionController

/// Trusted coordinator responsible for managing the end-to-end multi-step scenario lifecycle:
/// Scenario → Current Step → Fresh Observe → Propose → Validate → Approve → Execute → Fresh Observe → Verify → Advance
///
/// Security Invariant:
/// LLM Output ≠ Authorization ≠ Execution ≠ Verification ≠ Scenario Control
/// The LLM has zero authority to advance steps, alter step ordering, modify verification criteria,
/// bypass approval, declare completion, or trigger execution.
@MainActor
public final class ScenarioExecutionController: ObservableObject {

    // MARK: - Dependencies

    public let catalog: ScenarioCatalog
    public let validator: TrustedActionValidator
    public var clock: any ClockProtocol

    // MARK: - Active Scenario State

    @Published public private(set) var activeScenario: SafeScenario?
    @Published public var currentStepIndex: Int = 0
    @Published public var scenarioLifecycle: ClosedLoopState = .idle
    @Published public var stepLifecycle: ScenarioPhase = .ready

    @Published public var activeObservation: Observation?
    @Published public private(set) var observationCount: Int = 0
    @Published public private(set) var executionCount: Int = 0
    /// The most recent dispatch's execution ID, kept so failure-classification and recovery events that follow a dispatch
    /// carry the same correlation ID. Cleared when the next proposal arrives.
    private var lastExecutionID: String?
    /// Created before approval and consumed unchanged by authorization and dispatch.
    private var pendingExecutionID: String?
    private var pendingWorkflowExecutionID: String?
    private var pendingSimulatorUDID: String = SimulatorTargetConfiguration.current.udid
    private var pendingPreviewSession: PreviewSessionIdentity?
    /// Artifact references the last dispatch's tool produced (references only; bytes live in the artifact store).
    public private(set) var lastExecutionArtifacts: [ArtifactReference] = []
    @Published public private(set) var completedStepCount: Int = 0

    @Published public private(set) var lastVerifiedStep: ScenarioStep?
    @Published public private(set) var lastVerifiedSnapshotID: String?
    @Published public private(set) var lastVerificationResult: ScenarioVerificationResult?

    @Published public private(set) var activeApproval: HITLApprovalRequest?
    @Published public var isExecutingStep: Bool = false

    // MARK: - Safety Limits & Timeout

    @Published public var runLimits: AgentRunLimits
    @Published public var scenarioTimeoutSeconds: TimeInterval
    @Published public var executionMode: ExecutionMode = .simulation
    @Published public private(set) var scenarioStartedAt: Date?
    @Published public private(set) var cancellationReason: String?

    @Published public private(set) var consecutiveFailures: Int = 0
    @Published public private(set) var consecutiveNoProgressCount: Int = 0

    // MARK: - Diagnostics & Audit

    @Published public private(set) var runDiagnostics: [ClosedLoopDiagnostics] = []
    public private(set) var executedFingerprintsForCurrentSnapshot: Set<TrustedActionFingerprint> = []

    // MARK: - Recovery & Run Trace

    @Published public var recoveryBudgetTracker: RecoveryBudgetTracker = RecoveryBudgetTracker()
    @Published public private(set) var activeRunTrace: RunTrace? = nil

    /// Real, enforced pause control. When true, the trusted spine refuses to accept new
    /// proposals (`handleProposal`) or dispatch already-approved steps (`dispatchCurrentStep`).
    /// The Inspector's "Pause" toggle is synced into this property (see `AgentUIState`) so the
    /// UI control actually blocks execution rather than being decorative.
    @Published public var isPaused: Bool = false

    // MARK: - Product Layer: Failure Classification, Recovery, Tracing

    public var failureClassifier = FailureClassifier()
    /// Decision component only. It has no driver/ToolRegistry reference; see `RecoveryController`.
    public var recoveryController = RecoveryController()
    @Published public private(set) var lastFailureClass: FailureClass?
    @Published public private(set) var lastRecoveryDecision: RecoveryDecision?
    /// Invoked exactly once when a run reaches a terminal outcome, so callers can persist history.
    public var onRunFinished: ((RunTrace) -> Void)? {
        get { lifecycle.onRunFinished }
        set { lifecycle.onRunFinished = newValue }
    }
    /// True after `resumeAfterRestart`: nothing may be proposed until a fresh observation exists.
    @Published public private(set) var requiresFreshObservation: Bool = false
    private var rejectedProposalFingerprints: Set<String> = []
    /// Operational diagnostics only. Never consulted by any decision; `NullLogger` by default.
    public var logger: any AppLogger = NullLogger()

    /// Exactly-once run finalization (see `RunLifecycleCoordinator`).
    private var lifecycle = RunLifecycleCoordinator()
    private let dispatcher = ScenarioStepDispatcher()

    // MARK: - Initializer

    public init(
        catalog: ScenarioCatalog = ScenarioCatalog.shared,
        validator: TrustedActionValidator = TrustedActionValidator(),
        clock: any ClockProtocol = SystemClock(),
        runLimits: AgentRunLimits = AgentRunLimits(),
        scenarioTimeoutSeconds: TimeInterval = 120.0
    ) {
        self.catalog = catalog
        self.validator = validator
        self.clock = clock
        self.runLimits = runLimits
        self.scenarioTimeoutSeconds = scenarioTimeoutSeconds
    }

    // MARK: - Computed Properties

    public var activeStep: ScenarioStep? {
        guard let scenario = activeScenario else { return nil }
        guard currentStepIndex >= 0 && currentStepIndex < scenario.steps.count else { return nil }
        return scenario.steps[currentStepIndex]
    }

    public var isCompleted: Bool {
        scenarioLifecycle == .completed
    }

    public var isCancelled: Bool {
        scenarioLifecycle == .cancelled
    }


    // MARK: - Logging (observational)

    /// Emits a structured event correlated by run, scenario, step, approval, snapshot and execution.
    private func log(
        _ level: LogLevel, _ category: LogCategory, _ event: String, _ message: String = "",
        step: ScenarioStep? = nil, snapshotID: String? = nil, executionID: String? = nil,
        approvalID: String? = nil, toolName: String? = nil, proposalID: String? = nil,
        fields: [String: LogValue] = [:], duration: Double? = nil, errorClass: String? = nil
    ) {
        guard logger.isEnabled(level) else { return }
        let context = LogContext(
            runID: activeRunTrace?.runID, scenarioID: activeScenario?.id, stepID: (step ?? activeStep)?.id,
            proposalID: proposalID, approvalID: approvalID ?? activeApproval?.id.uuidString,
            snapshotID: snapshotID ?? activeObservation?.snapshotID, executionID: executionID,
            toolName: toolName ?? (step ?? activeStep)?.toolName
        )
        logger.log(level, category, event, message, context: context, fields: fields, duration: duration, errorClass: errorClass)
    }

    // MARK: - Scenario Lifecycle Control

    /// Starts a scenario directly at Step 0, resetting all run counters and recording start time.
    @discardableResult
    public func startScenario(_ scenario: SafeScenario) -> Bool {
        guard !isExecutingStep else { return false }

        self.activeScenario = scenario
        self.currentStepIndex = 0
        self.completedStepCount = 0
        self.observationCount = 0
        self.executionCount = 0
        self.consecutiveFailures = 0
        self.consecutiveNoProgressCount = 0
        self.cancellationReason = nil
        self.lastVerifiedStep = nil
        self.lastVerifiedSnapshotID = nil
        self.lastVerificationResult = nil
        self.activeApproval = nil
        self.pendingExecutionID = nil
        self.pendingWorkflowExecutionID = nil
        self.pendingPreviewSession = nil
        self.isExecutingStep = false
        self.executedFingerprintsForCurrentSnapshot.removeAll()
        self.scenarioStartedAt = clock.now()
        self.scenarioLifecycle = .observing
        self.stepLifecycle = .ready

        self.recoveryBudgetTracker.reset()
        self.recoveryController.reset()
        self.lastFailureClass = nil
        self.lastRecoveryDecision = nil
        self.requiresFreshObservation = false
        self.rejectedProposalFingerprints.removeAll()
        self.lifecycle.beginRun()
        self.activeRunTrace = RunTrace(scenarioID: scenario.id)
        self.activeRunTrace?.append(eventType: .runStarted, result: "Scenario '\(scenario.id)' initialized at Step 0.")
        return true
    }

    /// Starts a scenario from the catalog at Step 0, resetting all run counters and recording start time.
    @discardableResult
    public func startScenario(id: String) -> Bool {
        guard !isExecutingStep else { return false }
        guard let scenario = catalog.findScenario(by: id) else { return false }
        return startScenario(scenario)
    }

    /// Sets the active observation for the controller, incrementing the observation count
    /// and invalidating stale approvals or fingerprints.
    public func recordObservation(_ obs: Observation) {
        let isNewSnapshot = (self.activeObservation?.snapshotID != obs.snapshotID)
        self.requiresFreshObservation = false
        self.activeObservation = obs
        self.observationCount += 1
        if isNewSnapshot {
            self.executedFingerprintsForCurrentSnapshot.removeAll()
        }

        self.activeRunTrace?.append(
            eventType: .observed,
            snapshotID: obs.snapshotID,
            result: "Observation captured with \(obs.elements.count) elements."
        )

        if let pending = activeApproval, pending.status == .pending, pending.snapshotID != obs.snapshotID {
            activeApproval = nil
        }

        if scenarioLifecycle == .observing || scenarioLifecycle == .advancing {
            scenarioLifecycle = .proposing
        }
    }

    /// Checks if the scenario execution has exceeded its trusted time limit.
    public func checkTimeout() -> (isTimedOut: Bool, reason: String?) {
        guard let started = scenarioStartedAt else { return (false, nil) }
        let elapsed = clock.now().timeIntervalSince(started)
        if elapsed >= scenarioTimeoutSeconds {
            let reason = "Scenario execution timed out: elapsed \(Int(elapsed))s exceeded limit of \(Int(scenarioTimeoutSeconds))s."
            if scenarioLifecycle != .cancelled && scenarioLifecycle != .completed {
                scenarioLifecycle = .blocked
                stepLifecycle = .actionFailed
            }
            return (true, reason)
        }
        return (false, nil)
    }

    /// Checks if any safety run limits have been reached.
    public func checkLimits() -> (allowed: Bool, reason: String?) {
        if executionCount >= runLimits.maxSteps {
            let reason = "Execution halted: maximum step limit reached (\(executionCount)/\(runLimits.maxSteps))."
            scenarioLifecycle = .blocked
            return (false, reason)
        }
        if observationCount >= runLimits.maxObservations {
            let reason = "Execution halted: maximum observation limit reached (\(observationCount)/\(runLimits.maxObservations))."
            scenarioLifecycle = .blocked
            return (false, reason)
        }
        if consecutiveFailures >= runLimits.maxConsecutiveFailures {
            let reason = "Execution halted: maximum consecutive failure limit reached (\(consecutiveFailures)/\(runLimits.maxConsecutiveFailures))."
            scenarioLifecycle = .blocked
            return (false, reason)
        }
        if consecutiveNoProgressCount >= runLimits.maxNoProgressSteps {
            let reason = "Execution halted: maximum no-progress step limit reached (\(consecutiveNoProgressCount)/\(runLimits.maxNoProgressSteps))."
            scenarioLifecycle = .blocked
            return (false, reason)
        }
        return (true, nil)
    }

    // MARK: - Proposal Validation & Step Ordering Enforcement

    /// Validates an untrusted LLM proposal against the current active step, snapshot freshness, and policy.
    /// Rejects step skipping, step replay, out-of-order execution, and unauthorized tools.
    public func handleProposal(_ proposal: ActionProposal) -> Result<HITLApprovalRequest, LLMProposalPipelineError> {
        let fingerprint = proposal.fingerprint.description
        activeRunTrace?.append(
            eventType: .proposalReceived, stepID: proposal.stepID ?? activeStep?.id, snapshotID: proposal.snapshotID,
            result: "Proposal for element '\(proposal.elementID)' role '\(proposal.expectedRole)' tool '\(proposal.toolName)'.",
            proposalFingerprint: fingerprint
        )
        log(.debug, .proposal, "proposal.received", proposalID: fingerprint,
            fields: ["toolName": .string(proposal.toolName)])
        let result = handleProposalCore(proposal)
        switch result {
        case .success(let request):
            log(.info, .validation, "proposal.validated", approvalID: request.id.uuidString, proposalID: fingerprint)
            log(.notice, .approval, "approval.requested", approvalID: request.id.uuidString, proposalID: fingerprint,
                fields: ["ttlSeconds": .int(Int(ApprovalPolicy.tokenTimeToLive))])
            activeRunTrace?.append(
                eventType: .proposalValidated, stepID: activeStep?.id, snapshotID: proposal.snapshotID,
                result: "Validated element '\(request.targetLocator?.elementID ?? proposal.elementID)' role '\(request.targetLocator?.role ?? proposal.expectedRole)' identifier '\(request.targetLocator?.identifier ?? "-")'.",
                proposalFingerprint: fingerprint
            )
            activeRunTrace?.append(
                eventType: .approvalRequested, stepID: activeStep?.id, snapshotID: proposal.snapshotID,
                result: "Awaiting supervisor approval (\(Int(ApprovalPolicy.tokenTimeToLive))s TTL).",
                proposalFingerprint: fingerprint, tokenID: request.id.uuidString
            )
        case .failure(let error):
            let message = error.localizedDescription
            log(.warning, .validation, "proposal.rejected", proposalID: fingerprint,
                errorClass: failureClassifier.classify(error).rawValue)
            activeRunTrace?.append(
                eventType: .proposalRejected, stepID: activeStep?.id, snapshotID: proposal.snapshotID,
                result: message, proposalFingerprint: fingerprint
            )
            // Pause/lifecycle guards are not failures of the step itself; do not consume recovery.
            let lower = message.lowercased()
            let isGuard = lower.contains("paused") || lower.contains("cancelled") || lower.contains("already completed") || lower.contains("blocked")
            if !isGuard {
                rejectedProposalFingerprints.insert(fingerprint)
                noteFailure(failureClassifier.classify(error), detail: message, proposalFingerprint: fingerprint)
            }
        }
        return result
    }

    private func handleProposalCore(_ proposal: ActionProposal) -> Result<HITLApprovalRequest, LLMProposalPipelineError> {
        lastExecutionID = nil
        // -1. Restart gate: after a crash/restart nothing proceeds without a fresh observation.
        if requiresFreshObservation {
            return .failure(.validationFailed(reason: "Run resumed after restart: a fresh observation is required before any proposal is accepted."))
        }

        // 0. Pause gate: a paused controller accepts no new proposals.
        if isPaused {
            return .failure(.validationFailed(reason: "Execution is paused by human supervisor. New proposals are not accepted until resumed."))
        }

        // 1. Guard against illegal lifecycle states
        if scenarioLifecycle == .cancelled {
            return .failure(.validationFailed(reason: "Scenario is cancelled: \(cancellationReason ?? "Supervisor cancelled run.")."))
        }
        if scenarioLifecycle == .completed {
            return .failure(.validationFailed(reason: "Scenario is already completed. No further steps permitted."))
        }
        if scenarioLifecycle == .blocked {
            return .failure(.validationFailed(reason: "Scenario is blocked due to safety limits."))
        }

        // 2. Timeout check
        let timeoutCheck = checkTimeout()
        if timeoutCheck.isTimedOut {
            return .failure(.validationFailed(reason: timeoutCheck.reason ?? "Scenario timed out."))
        }

        // 3. Run limits check
        let limitsCheck = checkLimits()
        if !limitsCheck.allowed {
            return .failure(.validationFailed(reason: limitsCheck.reason ?? "Run limits exceeded."))
        }

        guard let runningScenario = activeScenario else {
            return .failure(.validationFailed(reason: "No active scenario selected."))
        }
        guard proposal.scenarioID == runningScenario.id else {
            return .failure(.validationFailed(reason: "Scenario mismatch: proposal targeted '\(proposal.scenarioID)', but the active scenario is '\(runningScenario.id)'."))
        }
        guard let currentStep = activeStep else {
            return .failure(.validationFailed(reason: "All scenario steps have already been completed."))
        }

        scenarioLifecycle = .validating

        // 4-7. Step ordering, duplicate detection, TrustedActionValidator and trusted argument
        // reconstruction are decided by `ProposalAdmission`; the controller applies the verdict.
        switch ProposalAdmission(validator: validator).admit(
            proposal, step: currentStep, stepIndex: currentStepIndex, observation: activeObservation,
            existingApproval: activeApproval, executedFingerprints: executedFingerprintsForCurrentSnapshot,
            now: clock.now()
        ) {
        case .rejected(let error):
            scenarioLifecycle = .failed
            return .failure(error)
        case .accepted(let req):
            self.activeApproval = req
            if pendingWorkflowExecutionID == nil { pendingExecutionID = UUID().uuidString }
            self.scenarioLifecycle = .awaitingApproval
            self.stepLifecycle = .actionProposed
            return .success(req)
        }
    }

    // MARK: - Skill Retrieval & Self-Healing Pipeline

    // MARK: - Human Approval Gating

    /// Binds security-relevant dispatch identity before the request can be approved.
    func bindPendingExecutionContext(executionID: String, simulatorUDID: String,
                                     workflowExecutionID: String? = nil,
                                     previewSession: PreviewSessionIdentity? = nil) {
        guard activeApproval?.status != .approved else { return }
        pendingExecutionID = executionID
        pendingWorkflowExecutionID = workflowExecutionID
        pendingSimulatorUDID = simulatorUDID
        pendingPreviewSession = previewSession
    }

    /// Approves the current pending step approval request.
    package func approveCurrentStep(source: HITLApprovalDecisionSource) {
        let timeoutCheck = checkTimeout()
        guard !timeoutCheck.isTimedOut else { return }

        guard var approval = activeApproval, approval.status == .pending else { return }
        let now = clock.now()
        if now >= approval.expiresAt || approval.status == .expired {
            HITLApprovalAuthority.expire(&approval, reason: ApprovalPolicy.expiredMessage)
            activeApproval = approval
            scenarioLifecycle = .failed
            stepLifecycle = .actionFailed
            activeRunTrace?.append(
                eventType: .approvalExpired, stepID: activeStep?.id, snapshotID: approval.snapshotID,
                result: "Single-use approval token expired before authorization (\(Int(ApprovalPolicy.tokenTimeToLive))s TTL).",
                tokenID: approval.id.uuidString, failureClass: .approvalExpired
            )
            log(.warning, .approval, "approval.expired", errorClass: FailureClass.approvalExpired.rawValue)
            noteFailure(.approvalExpired, detail: ApprovalPolicy.expiredMessage)
            return
        }

        guard let observation = activeObservation,
              let executionID = pendingExecutionID else { return }
        let context = AuthorizationContext(
            bundleID: observation.bundleID,
            simulatorUDID: observation.simulatorUDID ?? pendingSimulatorUDID,
            executionMode: executionMode,
            executionID: executionID,
            workflowExecutionID: pendingWorkflowExecutionID,
            previewSession: pendingPreviewSession
        )
        guard HITLApprovalAuthority.approve(&approval, source: source, context: context, at: now) else { return }
        activeApproval = approval
        stepLifecycle = .actionApproved
        log(.notice, .approval, "approval.approved", approvalID: approval.id.uuidString)
        activeRunTrace?.append(
            eventType: .approvalGranted, stepID: activeStep?.id, snapshotID: approval.snapshotID,
            result: "Supervisor authorization granted; single-use token issued.",
            proposalFingerprint: approval.fingerprint?.description, tokenID: approval.id.uuidString
        )
        activeRunTrace?.append(
            eventType: .tokenIssued, stepID: activeStep?.id, snapshotID: approval.snapshotID,
            result: "Single-use approval token active until \(approval.expiresAt).",
            tokenID: approval.id.uuidString
        )
    }

    /// Explicitly denies the current step approval request.
    public func denyCurrentStep(reason: String = "Action denied by human supervisor.") {
        if var approval = activeApproval {
            HITLApprovalAuthority.deny(&approval, reason: reason)
            activeApproval = approval
        }
        scenarioLifecycle = .failed
        stepLifecycle = .actionFailed
        activeRunTrace?.append(
            eventType: .approvalDenied, stepID: activeStep?.id, snapshotID: activeApproval?.snapshotID,
            result: reason, tokenID: activeApproval?.id.uuidString, failureClass: .approvalDenied
        )
        log(.notice, .approval, "approval.denied", errorClass: FailureClass.approvalDenied.rawValue)
        noteFailure(.approvalDenied, detail: reason)
    }

    // MARK: - Step Dispatch & Closed-Loop Execution

    /// Dispatches the approved step, captures fresh post-action observation,
    /// verifies post-condition deterministically, and advances currentStepIndex upon success.
    @discardableResult
    public func dispatchCurrentStep(
        toolRegistry: ToolRegistry,
        bundleID: String = SimulatorTargetConfiguration.current.bundleID,
        isLive: Bool? = nil,
        executionID externalExecutionID: String? = nil
    ) async -> Result<ScenarioVerificationResult, DriverError> {
        await dispatchCurrentStep(
            driver: toolRegistry.executionDriver, toolRegistry: toolRegistry,
            bundleID: bundleID,
            isLive: isLive, executionID: externalExecutionID
        )
    }

    /// Package-only injection seam retained for deterministic driver fault tests. Production
    /// callers use the registry-owned driver through the public overload above.
    package func dispatchCurrentStep(
        driver: any DeviceDriver,
        toolRegistry: ToolRegistry,
        bundleID: String = SimulatorTargetConfiguration.current.bundleID,
        isLive: Bool? = nil,
        executionID externalExecutionID: String? = nil
    ) async -> Result<ScenarioVerificationResult, DriverError> {
        let result = await dispatchCurrentStepCore(
            driver: driver, toolRegistry: toolRegistry,
            bundleID: bundleID, isLive: isLive, externalExecutionID: externalExecutionID
        )
        switch result {
        case .failure(let error):
            let message = error.localizedDescription
            let lower = message.lowercased()
            // Pause/concurrency/lifecycle guards refuse to run; they are not step failures.
            if !(lower.contains("paused") || lower.contains("concurrent") || lower.contains("illegal transition")) {
                noteFailure(failureClassifier.classify(error), detail: message)
            }
        case .success(let verification):
            if !verification.verified {
                noteFailure(.verificationFailed, detail: verification.reason)
            } else {
                // A verified step ends any recovery episode for the run's ladder bookkeeping.
                lastFailureClass = nil
                lastRecoveryDecision = nil
            }
        }
        return result
    }

    private func dispatchCurrentStepCore(
        driver: any DeviceDriver,
        toolRegistry: ToolRegistry,
        bundleID: String,
        isLive: Bool?,
        externalExecutionID: String?
    ) async -> Result<ScenarioVerificationResult, DriverError> {
        // Pause gate: checked BEFORE anything else (including the live-mode driver toggle) so a
        // paused controller cannot dispatch under any circumstance.
        guard !isPaused else {
            return .failure(.actionFailed("Execution is paused by human supervisor. Dispatch blocked until resumed."))
        }

        let liveMode = isLive ?? (executionMode == .live)
        await dispatcher.configureLiveMode(driver: driver, enabled: liveMode)

        // Concurrency lock
        guard !isExecutingStep else {
            return .failure(.actionFailed("Concurrent step dispatch blocked: step is already executing."))
        }

        // State machine validations
        guard scenarioLifecycle != .completed else {
            return .failure(.actionFailed("Illegal transition: completed scenario cannot execute additional steps."))
        }
        guard scenarioLifecycle != .cancelled else {
            return .failure(.actionFailed("Illegal transition: cancelled scenario cannot execute steps."))
        }
        guard scenarioLifecycle != .blocked else {
            return .failure(.actionFailed("Illegal transition: blocked scenario cannot execute steps."))
        }

        let timeoutCheck = checkTimeout()
        if timeoutCheck.isTimedOut {
            return .failure(.actionFailed(timeoutCheck.reason ?? "Scenario execution timed out."))
        }

        let limitsCheck = checkLimits()
        if !limitsCheck.allowed {
            return .failure(.actionFailed(limitsCheck.reason ?? "Safety limits exceeded."))
        }

        guard let scenario = activeScenario else {
            return .failure(.actionFailed("No active scenario."))
        }
        guard let step = activeStep else {
            return .failure(.actionFailed("All steps completed."))
        }

        guard var approval = activeApproval else {
            scenarioLifecycle = .failed
            stepLifecycle = .actionFailed
            return .failure(.actionFailed("No approval request found for active step."))
        }

        guard let executionID = pendingExecutionID else {
            return .failure(.actionFailed("No execution identity was bound before approval."))
        }
        let dispatchExecutionID = externalExecutionID ?? executionID
        let dispatchContext = AuthorizationContext(
            bundleID: bundleID,
            simulatorUDID: toolRegistry.simulatorDestinationID,
            executionMode: liveMode ? .live : .simulation,
            executionID: dispatchExecutionID,
            workflowExecutionID: pendingWorkflowExecutionID,
            previewSession: pendingPreviewSession
        )

        // Trusted pre-dispatch authorization (TTL, denial, status, tool identity, target identity,
        // snapshot freshness) re-checked against the CURRENT observation. Pure; verdict applied here.
        let authorization: DispatchAuthorizer.Authorized
        let obs: Observation
        switch DispatchAuthorizer().authorize(approval: approval, step: step, observation: activeObservation,
                                              context: dispatchContext, now: clock.now()) {
        case .rejected(let rejection):
            log(.warning, .authorization, "authorization.rejected", approvalID: approval.id.uuidString,
                errorClass: failureClassifier.classify(rejection.error).rawValue)
            approval.driverInvoked = false
            if let status = rejection.newStatus {
                switch status {
                case .expired: HITLApprovalAuthority.expire(&approval, reason: rejection.blockedReason)
                case .denied: HITLApprovalAuthority.deny(&approval, reason: rejection.blockedReason)
                case .failed: HITLApprovalAuthority.fail(&approval, reason: rejection.blockedReason)
                case .pending, .approved, .executing, .succeeded: break
                }
            }
            if let reason = rejection.blockedReason { approval.blockedReason = reason }
            activeApproval = approval
            scenarioLifecycle = .failed
            stepLifecycle = .actionFailed
            return .failure(rejection.error)
        case .authorized(let authorized):
            obs = authorized.observation
            authorization = authorized
        }

        // Consume single-use execution token immediately
        guard HITLApprovalAuthority.consume(&approval, grant: authorization.approvalGrant) else {
            scenarioLifecycle = .failed
            stepLifecycle = .actionFailed
            return .failure(.actionFailed("Approval grant was already consumed or no longer matches the request."))
        }
        approval.driverInvoked = false
        activeApproval = approval
        scenarioLifecycle = .executing
        stepLifecycle = .actionExecuting
        isExecutingStep = true
        executionCount += 1
        // The execution ID was created before approval and is consumed unchanged here.
        lastExecutionID = executionID
        lastExecutionArtifacts = []
        log(.notice, .authorization, "authorization.issued", step: step, snapshotID: obs.snapshotID,
            executionID: executionID, approvalID: approval.id.uuidString)
        log(.info, .execution, "execution.dispatch.started", step: step, snapshotID: obs.snapshotID, executionID: executionID,
            approvalID: approval.id.uuidString)

        if let fp = approval.fingerprint {
            executedFingerprintsForCurrentSnapshot.insert(fp)
        }

        let initialSnapID = obs.snapshotID
        let approvalID = approval.id.uuidString
        let fingerprintStr = approval.fingerprint?.description
        let executionStartedAt = Date()
        activeRunTrace?.append(
                executionID: executionID, toolName: step.toolName, actionType: ToolCatalog.descriptor(for: step.toolName)?.canonicalName,
            eventType: .executionStarted, stepID: step.id, snapshotID: initialSnapID,
            result: "Single-use token consumed; dispatching '\(step.toolName)' through ToolRegistry.",
            proposalFingerprint: fingerprintStr, tokenID: approvalID
        )

        // Driver Execution
        let toolCall = dispatcher.toolCall(for: step, approval: approval)

        approval.driverInvoked = true
        activeApproval = approval
        log(.debug, .tool, "execution.tool.started", step: step, snapshotID: initialSnapID, executionID: executionID)

        let toolResult: ToolResult
        do {
            toolResult = try await dispatcher.execute(
                toolCall, authorization: authorization, toolRegistry: toolRegistry,
                association: ArtifactAssociation(runID: activeRunTrace?.runID, scenarioID: scenario.id, stepID: step.id)
            )
            HITLApprovalAuthority.succeed(&approval)
            approval.driverInvoked = true
            approval.executionSummary = toolResult.summary
            lastExecutionArtifacts = toolResult.artifacts
            activeApproval = approval
            log(.info, .tool, "execution.tool.completed", step: step, snapshotID: initialSnapID, executionID: executionID,
                duration: Date().timeIntervalSince(executionStartedAt))
            activeRunTrace?.append(
                executionID: executionID, toolName: step.toolName, actionType: ToolCatalog.descriptor(for: step.toolName)?.canonicalName,
                eventType: .executionFinished, stepID: step.id, snapshotID: initialSnapID,
                result: "XCTest dispatch completed.",
                proposalFingerprint: fingerprintStr, tokenID: approvalID,
                durationSeconds: Date().timeIntervalSince(executionStartedAt)
            )
        } catch {
            isExecutingStep = false
            log(.error, .tool, "execution.step.failed", step: step, snapshotID: initialSnapID, executionID: executionID,
                duration: Date().timeIntervalSince(executionStartedAt), errorClass: ((error as? DriverError).map { failureClassifier.classify($0) } ?? .unknown).rawValue)
            HITLApprovalAuthority.fail(&approval)
            approval.driverInvoked = true
            approval.executionError = error.localizedDescription
            activeApproval = approval
            activeRunTrace?.append(
                executionID: executionID, toolName: step.toolName, actionType: ToolCatalog.descriptor(for: step.toolName)?.canonicalName,
                eventType: .executionFinished, stepID: step.id, snapshotID: initialSnapID,
                result: "XCTest dispatch failed: \(error.localizedDescription)",
                proposalFingerprint: fingerprintStr, tokenID: approvalID,
                durationSeconds: Date().timeIntervalSince(executionStartedAt)
            )

            consecutiveFailures += 1
            consecutiveNoProgressCount += 1
            scenarioLifecycle = .failed
            stepLifecycle = .actionFailed

            let diag = ClosedLoopDiagnostics(
                runID: activeRunTrace?.runID,
                scenarioID: scenario.id,
                stepID: step.id,
                snapshotID: initialSnapID,
                currentStepIndex: currentStepIndex,
                fingerprint: fingerprintStr,
                approvalID: approvalID,
                executionID: executionID,
                driverInvoked: true,
                driverSucceeded: false,
                postObservationSnapshotID: nil,
                scenarioVerified: false,
                progressDetected: false,
                failureReason: error.localizedDescription,
                verificationResult: "Driver execution failed: \(error.localizedDescription)",
                transition: "executing -> failed",
                cancellationReason: nil,
                timestamp: clock.now()
            )
            runDiagnostics.append(diag)

            if let dErr = error as? DriverError {
                return .failure(dErr)
            }
            return .failure(.actionFailed(error.localizedDescription))
        }

        // Post-Execution Fresh Observation
        scenarioLifecycle = .postObserving
        let postObs: Observation
        do {
            postObs = try await dispatcher.captureFreshObservation(driver: driver, bundleID: bundleID)
            self.activeObservation = postObs
            self.observationCount += 1
            log(.info, .observation, "execution.observation.completed", step: step, snapshotID: postObs.snapshotID,
                executionID: executionID, fields: ["elementCount": .int(postObs.elements.count)])
            self.executedFingerprintsForCurrentSnapshot.removeAll()
            activeRunTrace?.append(
                executionID: executionID, toolName: step.toolName, actionType: ToolCatalog.descriptor(for: step.toolName)?.canonicalName,
                eventType: .postObserved, stepID: step.id, snapshotID: postObs.snapshotID,
                result: "Fresh post-action observation with \(postObs.elements.count) elements (previous snapshot \(initialSnapID))."
            )
        } catch {
            isExecutingStep = false
            scenarioLifecycle = .failed
            stepLifecycle = .actionFailed
            return .failure(.actionFailed("Failed to capture fresh observation after execution: \(error.localizedDescription)"))
        }

        // Progress Detection & Recovery Budget Check (Parts 6 & 7)
        let progressEval = ProgressDetector().detectProgress(before: obs, after: postObs)
        if progressEval.hasProgress {
            self.consecutiveNoProgressCount = 0
            self.recoveryBudgetTracker.recordProgress()
        } else {
            self.consecutiveNoProgressCount += 1
            self.recoveryBudgetTracker.recordNoProgress()
        }

        let (isBudgetExhausted, budgetReason) = self.recoveryBudgetTracker.isExhausted
        if isBudgetExhausted {
            self.isExecutingStep = false
            self.scenarioLifecycle = .blocked
            self.stepLifecycle = .actionFailed
            self.activeRunTrace?.append(
                executionID: executionID, toolName: step.toolName, actionType: ToolCatalog.descriptor(for: step.toolName)?.canonicalName,
                eventType: .budgetExceeded,
                stepID: step.id,
                snapshotID: postObs.snapshotID,
                result: budgetReason ?? "Recovery budget exhausted."
            )
            return .failure(.actionFailed(budgetReason ?? "Recovery budget exhausted."))
        }

        // Deterministic Verification
        scenarioLifecycle = .verifying
        let verifResult = ScenarioVerificationService().verify(step: step, scenario: scenario, observation: postObs, pre: obs)
        log(verifResult.verified ? .info : .warning, .verification, "execution.verification.completed", step: step,
            snapshotID: postObs.snapshotID, executionID: executionID, fields: ["verified": .bool(verifResult.verified)],
            errorClass: verifResult.verified ? nil : FailureClass.verificationFailed.rawValue)

        self.lastVerificationResult = verifResult
        self.isExecutingStep = false

        if verifResult.verified {
            consecutiveFailures = 0
            consecutiveNoProgressCount = 0
            completedStepCount += 1
            lastVerifiedStep = step
            lastVerifiedSnapshotID = postObs.snapshotID
            activeRunTrace?.append(
                executionID: executionID, toolName: step.toolName, actionType: ToolCatalog.descriptor(for: step.toolName)?.canonicalName,
                eventType: .verificationPassed, stepID: step.id, snapshotID: postObs.snapshotID,
                result: verifResult.reason,
                proposalFingerprint: fingerprintStr, tokenID: approvalID,
                durationSeconds: Date().timeIntervalSince(executionStartedAt)
            )

            let nextIndex = currentStepIndex + 1
            let isFinalStep = nextIndex >= scenario.steps.count

            let nextLifecycle: ClosedLoopState = isFinalStep ? .completed : .advancing
            self.scenarioLifecycle = nextLifecycle
            self.stepLifecycle = isFinalStep ? .restored : .ready

            if !isFinalStep {
                self.currentStepIndex = nextIndex
                self.scenarioLifecycle = .observing
            }

            let diag = ClosedLoopDiagnostics(
                runID: activeRunTrace?.runID,
                scenarioID: scenario.id,
                stepID: step.id,
                snapshotID: initialSnapID,
                currentStepIndex: currentStepIndex,
                fingerprint: fingerprintStr,
                approvalID: approvalID,
                executionID: executionID,
                driverInvoked: true,
                driverSucceeded: true,
                postObservationSnapshotID: postObs.snapshotID,
                scenarioVerified: true,
                progressDetected: true,
                failureReason: nil,
                verificationResult: verifResult.reason,
                transition: "verifying -> \(nextLifecycle.rawValue)",
                cancellationReason: nil,
                timestamp: clock.now()
            )
            runDiagnostics.append(diag)

            if isFinalStep {
                activeRunTrace?.append(
                executionID: executionID, toolName: step.toolName, actionType: ToolCatalog.descriptor(for: step.toolName)?.canonicalName,
                    eventType: .scenarioCompleted, stepID: step.id, snapshotID: postObs.snapshotID,
                    result: "All scenario steps verified."
                )
                finishRun(result: "COMPLETED")
            }

            return .success(verifResult)
        } else {
            consecutiveFailures += 1
            consecutiveNoProgressCount += 1
            recoveryBudgetTracker.recordFailure()
            activeRunTrace?.append(
                executionID: executionID, toolName: step.toolName, actionType: ToolCatalog.descriptor(for: step.toolName)?.canonicalName,
                eventType: .verificationFailed,
                stepID: step.id,
                snapshotID: postObs.snapshotID,
                result: verifResult.reason
            )

            let limitHit = (consecutiveNoProgressCount >= runLimits.maxNoProgressSteps || consecutiveFailures >= runLimits.maxConsecutiveFailures)
            self.scenarioLifecycle = limitHit ? .blocked : .failed
            self.stepLifecycle = .actionFailed

            let diag = ClosedLoopDiagnostics(
                runID: activeRunTrace?.runID,
                scenarioID: scenario.id,
                stepID: step.id,
                snapshotID: initialSnapID,
                currentStepIndex: currentStepIndex,
                fingerprint: fingerprintStr,
                approvalID: approvalID,
                executionID: executionID,
                driverInvoked: true,
                driverSucceeded: true,
                postObservationSnapshotID: postObs.snapshotID,
                scenarioVerified: false,
                progressDetected: false,
                failureReason: verifResult.reason,
                verificationResult: verifResult.reason,
                transition: "verifying -> \(scenarioLifecycle.rawValue)",
                cancellationReason: nil,
                timestamp: clock.now()
            )
            runDiagnostics.append(diag)

            return .success(verifResult)
        }
    }

    // MARK: - Product Layer: Failure Handling, Recovery Planning, Run Lifecycle

    /// Applies context that identifies WHAT was tested and HOW it was approved to the run trace,
    /// so a stored trace can never be mistaken for evidence of a different mode.
    public func configureRunContext(
        appIdentity: AppIdentity? = nil,
        simulatorID: String? = nil,
        simulatorName: String? = nil,
        executionMode: String? = nil
    ) {
        activeRunTrace?.setContext(
            appIdentity: appIdentity, simulatorID: simulatorID,
            simulatorName: simulatorName, executionMode: executionMode
        )
    }

    /// Records a failure, classifies it deterministically, and asks the `RecoveryController` for
    /// the next *safe* step. The returned decision is data only: acting on it means capturing a
    /// read-only observation, obtaining a new proposal, or a human step. Any resulting action is
    /// proposed and authorized through the normal pipeline — recovery never dispatches anything.
    @discardableResult
    public func noteFailure(
        _ failure: FailureClass,
        detail: String,
        proposalFingerprint: String? = nil
    ) -> RecoveryDecision {
        lastFailureClass = failure
        let ctx = RecoveryContext(
            scenario: activeScenario,
            stepIndex: currentStepIndex,
            observation: activeObservation,
            failure: failure,
            detail: detail,
            proposalWasAlreadyRejected: proposalFingerprint.map { rejectedProposalFingerprints.contains($0) && failure == .validationFailed && recoveryController.history.contains(where: { $0.failureClass == .validationFailed && $0.strategy == .requestNewLLMProposal }) } ?? false
        )
        let decision = recoveryController.decide(ctx, budget: &recoveryBudgetTracker)
        lastRecoveryDecision = decision

        activeRunTrace?.append(
            executionID: lastExecutionID, eventType: .failureClassified, stepID: activeStep?.id, snapshotID: activeObservation?.snapshotID,
            result: detail, proposalFingerprint: proposalFingerprint, failureClass: failure
        )
        activeRunTrace?.append(
            executionID: lastExecutionID, eventType: .recoveryDecided, stepID: activeStep?.id, snapshotID: activeObservation?.snapshotID,
            result: "\(decision.strategy?.rawValue ?? "none"): \(decision.explanation)",
            failureClass: failure
        )

        if case .failClosed = decision.action {
            activeRunTrace?.append(
                executionID: lastExecutionID, eventType: .budgetExceeded, stepID: activeStep?.id, snapshotID: activeObservation?.snapshotID,
                result: decision.explanation, failureClass: failure
            )
        }
        return decision
    }

    /// Emits the run's terminal event exactly once and hands the finished trace to `onRunFinished`.
    public func finishRun(result: String) {
        lifecycle.finish(trace: &activeRunTrace, stepID: activeStep?.id, result: result)
    }

    // MARK: - Cancellation

    /// Cancels scenario execution, invalidates any pending approval, and locks the state in .cancelled.
    public func cancel(reason: String = "Supervisor cancelled scenario run.") {
        self.cancellationReason = reason
        self.scenarioLifecycle = .cancelled
        self.stepLifecycle = .actionFailed
        self.isExecutingStep = false

        if var approval = activeApproval {
            HITLApprovalAuthority.deny(&approval, reason: reason)
            activeApproval = nil
        }
        activeRunTrace?.append(eventType: .scenarioCancelled, stepID: activeStep?.id, result: reason)
        finishRun(result: "CANCELLED")

        let diag = ClosedLoopDiagnostics(
            runID: activeRunTrace?.runID,
            scenarioID: activeScenario?.id ?? "unknown",
            stepID: activeStep?.id ?? "none",
            snapshotID: activeObservation?.snapshotID ?? "none",
            currentStepIndex: currentStepIndex,
            driverInvoked: false,
            driverSucceeded: false,
            scenarioVerified: false,
            progressDetected: false,
            failureReason: reason,
            verificationResult: nil,
            transition: "-> cancelled",
            cancellationReason: reason,
            timestamp: clock.now()
        )
        runDiagnostics.append(diag)
    }

    /// Resets the controller back to .idle state.
    public func reset() {
        self.activeScenario = nil
        self.currentStepIndex = 0
        self.scenarioLifecycle = .idle
        self.stepLifecycle = .ready
        self.activeObservation = nil
        self.observationCount = 0
        self.executionCount = 0
        self.completedStepCount = 0
        self.lastVerifiedStep = nil
        self.lastVerifiedSnapshotID = nil
        self.lastVerificationResult = nil
        self.activeApproval = nil
        self.isExecutingStep = false
        self.cancellationReason = nil
        self.consecutiveFailures = 0
        self.consecutiveNoProgressCount = 0
        self.scenarioStartedAt = nil
        self.executedFingerprintsForCurrentSnapshot.removeAll()
        self.recoveryBudgetTracker.reset()
        self.activeRunTrace = nil
    }
}
