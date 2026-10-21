import Foundation
import AgentCore
import AgentInfrastructure

extension CaseRunSession {
    /// Repeats a learned skill's actions through the same validated, approved, dispatched path as planned actions, then checks that
    /// the screen now shows everything the learned end screen showed. No planning and no judge. Returns false when any action fails
    /// or the end screen differs; the caller then plans the step normally.
    func replaySkill(_ skill: StepSkill, number: Int) async -> Bool {
        for (index, learned) in skill.actions.enumerated() {
            let step = IRStep(id: "s\(index + 1)", sourceStepNumber: number, intent: learned.intent, action: learned.action, target: learned.target, arguments: learned.arguments,
                              verification: IRVerification(description: "action dispatched and the application is still in the foreground", signals: [.foregroundApplication(bundleID: bundleID)]))
            let ok = await runDocument(ir: TestIR(testKey: key, title: title, steps: [step]), rowPrefix: "\(number).k\(index + 1)", stepNumber: number, startStep: 0, humanNumbers: [],
                                       tentative: true, evidence: false)
            if !ok { return false }
        }
        await waitUntilScreenSettles()
        guard let after = await observe() else { return false }
        // Pages change between visits (promotions, results), so the end screen only has to look like the learned one.
        let matches = ScreenSignature(from: after).similarity(to: skill.postScreen) >= ScreenSignature.minimumEndMatch
        recordRow("\(number).skill", number: number, intent: skill.stepText, action: "skill", matches ? .passed : .skipped,
                  matches ? "replayed a learned skill (\(skill.actions.count) action(s)); the end screen matches the learned one"
                          : "replay: the end screen differs from the learned one; planning instead")
        return matches
    }

    /// Learns only from a step that finished verified: the caller has checked that the judge agreed (or there is no judge) and the
    /// run is live. A step that typed a credential is never learned.
    func learnSkill(into skills: StepSkillStore, stepNumber: Int, stepText: String, executed: [IRStep], verifiesOnly: Bool,
                    before: Observation, after: Observation) async {
        let actions = executed.filter { $0.action != .verifyOnly && $0.action != .waitForElement }
        guard executed.allSatisfy({ $0.credentialRef == nil }), !actions.isEmpty || verifiesOnly else { return }
        let skill = StepSkill(testKey: key, stepNumber: stepNumber, stepText: stepText, bundleID: bundleID,
                                 actions: actions.map { StepSkillAction(action: $0.action, target: $0.target, arguments: $0.arguments, intent: $0.intent) },
                                 preScreen: ScreenSignature(from: before), postScreen: ScreenSignature(from: after),
                                 approvalSource: "explicitAutomationPolicy")
        if await skills.save(skill) { print("  learned a skill for this step (\(actions.count) action(s))") }
    }
}
