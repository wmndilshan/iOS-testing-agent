import Foundation
import AgentCore
import AgentInfrastructure

/// Execution modes of the case runner. Only `.liveHumanApproval` reads a real approval from a human (stdin) and may
/// honestly claim HITL evidence; it is the gate for destructive actions. The other two are automated and always labeled so.
enum CLIExecutionMode: String {
    /// Real simulator dispatch and a REAL human approval read from stdin for every step.
    case liveHumanApproval = "LIVE_HUMAN_APPROVAL"
    /// Full trusted pipeline against the simulated driver, scripted approval. Never claims live mutation or HITL evidence.
    case nonLiveTest = "NON_LIVE_TEST"
    /// Real simulator dispatch where the operator delegated approval to the CLI policy (`explicitAutomationPolicy`).
    /// The human only types the password and logs in. Never counts as human-in-the-loop evidence.
    case liveAutonomousAfterLogin = "LIVE_AUTONOMOUS_AFTER_LOGIN"

    /// Whether this mode may present its approvals as genuine human-in-the-loop evidence.
    var isGenuineHumanApproval: Bool { self == .liveHumanApproval }

    /// Modes permitted to select production live mutation.
    var isLive: Bool { self == .liveHumanApproval || self == .liveAutonomousAfterLogin }

    static func parse(from args: [String]) -> CLIExecutionMode? {
        guard let modeArg = args.first(where: { $0.hasPrefix("--mode=") }) else {
            return nil
        }
        let value = String(modeArg.dropFirst("--mode=".count)).uppercased()
        return CLIExecutionMode(rawValue: value)
    }
}
