import Foundation
import AgentCore
import AgentInfrastructure

@MainActor
extension Engine {
    /// Requests supervisor approval for the currently pending step according to `mode`.
    ///
    /// Only `.liveHumanApproval` reads real input from stdin and may print a genuine
    /// "Authorization GRANTED" claim. The other modes auto-approve but always disclose that the
    /// approval was scripted by this process, not a human — the CLI must never print a human-
    /// authorization claim when none occurred. Returns `true` iff the step is now `.approved`.
    static func requestSupervisorApproval(
        mode: CLIExecutionMode,
        controller: ScenarioExecutionController,
        stepLabel: String
    ) -> Bool {
        switch mode {
        case .liveHumanApproval:
            print("Human Supervisor Action Required for \(stepLabel).")
            print("Type 'approve' to authorize execution, or anything else to deny: ", terminator: "")
            let input = StdinAnswers.shared.next(timeout: CaseRunSession.personWaitSeconds)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard input == "approve" else {
                print("✗ Human supervisor denied authorization (input: \(input ?? "no answer in time")).")
                controller.denyCurrentStep(reason: "Denied by human supervisor via CLI stdin.")
                return false
            }
            print("✓ Human Supervisor Action: Authorization GRANTED via real stdin confirmation (\"approve\").")
            controller.approveCurrentStep(source: .humanCLI)
            let approvedLive = controller.activeApproval?.status == .approved
            if !approvedLive {
                print("✗ Approval token was not in .approved state after approveCurrentStep() (status: \(controller.activeApproval?.status.rawValue ?? "nil")). Likely cause: the single-use approval token's TTL expired before authorization was relayed.")
            }
            return approvedLive
        case .nonLiveTest, .liveAutonomousAfterLogin:
            print("AUTOMATED SUPERVISED MODE: Authorization auto-granted by scripted CLI policy for")
            print("\(stepLabel) — NOT a human supervisor. This is not HITL evidence.")
            controller.approveCurrentStep(source: .explicitAutomationPolicy)
            let approvedAuto = controller.activeApproval?.status == .approved
            if !approvedAuto {
                print("✗ Approval token was not in .approved state after approveCurrentStep() (status: \(controller.activeApproval?.status.rawValue ?? "nil")).")
            }
            return approvedAuto
        }
    }
}
