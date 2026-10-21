import Foundation

public struct FailureClassifier: Sendable {

    public init() {}

    public func classify(_ error: DriverError) -> FailureClass {
        switch error {
        case .staleSnapshot: return .staleSnapshot
        case .elementNotFound: return .elementNotFound
        case .elementNotHittable, .elementDisabled: return .appStateMismatch
        case .typeMismatch: return .appStateMismatch
        case .ambiguousElement: return .ambiguousTarget
        case .simulatorNotAvailable: return .simulatorUnavailable
        case .observationFailed(let reason): return classifyMessage(reason, fallback: .observationFailed)
        case .unsupportedCapability: return .xctestFailed
        case .timedOut: return .appNotResponding
        case .wrongApplication: return .appStateMismatch
        case .actionFailed(let reason): return classifyMessage(reason, fallback: .xctestFailed)
        }
    }

    public func classify(_ error: LLMProposalPipelineError) -> FailureClass {
        switch error {
        case .validationFailed(let reason): return classifyMessage(reason, fallback: .validationFailed)
        case .duplicateProposal: return .validationFailed
        }
    }

    public func classify(approvalStatus: HITLApprovalStatus) -> FailureClass? {
        switch approvalStatus {
        case .expired: return .approvalExpired
        case .denied: return .approvalDenied
        default: return nil
        }
    }

    /// Deterministic message-shape classification for errors that only reach us as text
    /// (xcodebuild output, controller guards). Order matters: most specific first.
    public func classifyMessage(_ message: String, fallback: FailureClass = .unknown) -> FailureClass {
        let m = message.lowercased()

        if m.contains("approval expired") || m.contains("ttl expired") { return .approvalExpired }
        if m.contains("denied by") || m.contains("was denied") { return .approvalDenied }
        if m.contains("budget exhausted") || m.contains("limit reached") || (m.contains("exceeded limit") && m.contains("recovery")) {
            return .recoveryBudgetExhausted
        }
        if m.contains("stale snapshot") || m.contains("stale snapshot reference") { return .staleSnapshot }
        if m.contains("ambiguous") { return .ambiguousTarget }
        if m.contains("crashed") || m.contains("crash report") || (m.contains("terminated unexpectedly") && !m.contains("xcodebuild")) || m.contains("application state: not running") {
            return .appCrashed
        }
        if m.contains("failed to launch") || m.contains("launch failed") || m.contains("could not launch") {
            return .appLaunchFailed
        }
        if m.contains("not responding") || m.contains("did not become idle") || m.contains("timed out while evaluating ui query") {
            return .appNotResponding
        }
        if m.contains("unable to boot") || m.contains("is not running or accessible") || m.contains("no such device") || (m.contains("simulator") && (m.contains("not available") || m.contains("shutdown") || m.contains("not booted"))) {
            return .simulatorUnavailable
        }
        if m.contains("target element mismatch") || m.contains("role changed") || m.contains("identifier changed") {
            return .appStateMismatch
        }
        if m.contains("not found") || m.contains("is missing from active snapshot") { return .elementNotFound }
        if m.contains("observation") && m.contains("fail") { return .observationFailed }
        if m.contains("verification") && (m.contains("fail") || m.contains("lacks")) { return .verificationFailed }
        if m.contains("exited with status code") || m.contains("xcuitest execution failed") || m.contains("xcodebuild") {
            return .xctestFailed
        }
        return fallback
    }
}
