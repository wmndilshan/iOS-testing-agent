import Foundation

public struct TrustedActionValidator: Sendable {
    public let catalog: ScenarioCatalog

    public init(catalog: ScenarioCatalog = ScenarioCatalog.shared) {
        self.catalog = catalog
    }

    /// Validates an untrusted ActionProposal against the trusted ScenarioCatalog,
    /// active accessibility observation, and safety boundaries.
    /// Optionally validates against a specific active scenario step and step index.
    public func validate(
        proposal: ActionProposal,
        activeObservation: Observation?,
        activeStep: ScenarioStep? = nil,
        activeStepIndex: Int? = nil
    ) -> TrustedValidationResult {
        // 1. Scenario catalog existence check
        guard let scenario = catalog.findScenario(by: proposal.scenarioID) else {
            return .rejected(reason: "Unknown scenario ID '\(proposal.scenarioID)'. ScenarioCatalog is the safety source of truth.")
        }

        // 2. Read-only scenario policy check (ScenarioCatalog is truth)
        let normalizedToolName = proposal.toolName.replacingOccurrences(of: "-", with: "_")
        if !scenario.changesUIState && !SafeScenario.readOnlyScenarioTools.contains(normalizedToolName) {
            return .rejected(reason: "Scenario '\(scenario.id)' is read-only (changesUIState = false). Tool '\(proposal.toolName)' is not permitted.")
        }

        // 3. Active observation check
        guard let obs = activeObservation else {
            return .rejected(reason: "No active accessibility observation available to validate proposal.")
        }

        // 4. Snapshot ID binding check
        guard obs.snapshotID == proposal.snapshotID else {
            return .rejected(reason: "Stale snapshot ID. Proposal bound to '\(proposal.snapshotID)', but active observation is '\(obs.snapshotID)'.")
        }

        // 5. Element existence check in active observation
        guard let element = obs.elements.first(where: { $0.id == proposal.elementID }) else {
            return .rejected(reason: "Element '\(proposal.elementID)' does not exist in active snapshot '\(obs.snapshotID)'. Synthetic elements rejected.")
        }

        // 6. Element role match check
        guard element.role.lowercased() == proposal.expectedRole.lowercased() else {
            return .rejected(reason: "Element role mismatch. Element has role '\(element.role)', but proposal expected '\(proposal.expectedRole)'.")
        }

        // 7. Expected identifier / label check if provided
        if let expectedID = proposal.expectedIdentifier, !expectedID.isEmpty {
            let actualID = element.identifier ?? ""
            let actualLabel = element.label ?? ""
            if actualID != expectedID && actualLabel != expectedID {
                return .rejected(reason: "Element identifier/label mismatch. Element has identifier '\(actualID)' / label '\(actualLabel)', but proposal expected '\(expectedID)'.")
            }
        }

        // 8. Step ordering and active step validation
        let targetStep: ScenarioStep
        if let currentStep = activeStep {
            if let pIdx = proposal.stepIndex, let cIdx = activeStepIndex, pIdx != cIdx {
                return .rejected(reason: "Step ordering violation: proposal targeted step \(pIdx), but active step is \(cIdx) ('\(currentStep.name)').")
            }
            if let pStepID = proposal.stepID, pStepID != currentStep.id {
                return .rejected(reason: "Step ID violation: proposal targeted step '\(pStepID)', but active step is '\(currentStep.id)'.")
            }
            guard currentStep.locator.matches(element: element) else {
                return .rejected(reason: "Element '\(element.id)' does not match trusted scenario locator for active step '\(currentStep.name)'.")
            }
            targetStep = currentStep
        } else {
            // Legacy / unconstrained step check: matches actionStep or teardownStep if defined
            if let pIdx = proposal.stepIndex {
                if pIdx < 0 || pIdx >= scenario.steps.count {
                    return .rejected(reason: "Step index out of range: scenario has \(scenario.steps.count) steps, received \(pIdx).")
                }
            }
            if scenario.actionStep.locator.matches(element: element) {
                targetStep = scenario.actionStep
            } else if let teardown = scenario.teardownStep, teardown.locator.matches(element: element) {
                targetStep = teardown
            } else {
                return .rejected(reason: "Element '\(element.id)' does not match trusted scenario locator for step '\(scenario.actionStep.name)'.")
            }
        }

        // 9. Tool allowlist check against scenario step
        let normalizedStepTool = targetStep.toolName.replacingOccurrences(of: "-", with: "_")
        guard normalizedToolName == normalizedStepTool else {
            return .rejected(reason: "Tool '\(proposal.toolName)' is not allowlisted for scenario step. Allowed tool: '\(targetStep.toolName)'.")
        }

        return .valid(scenario: scenario, targetElement: element)
    }
}
