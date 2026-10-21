import Foundation

/// The pure admission decision for an untrusted proposal against the active step.
///
/// Order is fixed and fail-closed: step ordering, duplicate detection, `TrustedActionValidator`,
/// then rebuilding the execution arguments from trusted state only (the proposal may not supply or
/// override any security-sensitive identifier). It produces a *pending* approval request; it never
/// approves, never touches a driver and never mutates controller state. The controller applies the
/// verdict (lifecycle, `activeApproval`) after lifecycle, pause, timeout and limit guards have passed.
struct ProposalAdmission {
    let validator: TrustedActionValidator

    enum Verdict {
        case accepted(HITLApprovalRequest)
        case rejected(LLMProposalPipelineError)
    }

    /// Keys only the system may set. A proposal carrying any of them is rejected outright.
    static let securitySensitiveKeys: Set<String> = [
        "snapshotID", "elementID", "scenarioID", "stepID", "stepIndex",
        "toolName", "expectedRole", "expectedIdentifier", "locator"
    ]

    func admit(
        _ proposal: ActionProposal,
        step currentStep: ScenarioStep,
        stepIndex currentStepIndex: Int,
        observation: Observation?,
        existingApproval: HITLApprovalRequest?,
        executedFingerprints: Set<TrustedActionFingerprint>,
        now: Date
    ) -> Verdict {
        // Strict step ordering: no skipping, replaying or out-of-order execution.
        if let pIdx = proposal.stepIndex, pIdx != currentStepIndex {
            return .rejected(.validationFailed(reason: "Step ordering violation: proposal targeted step \(pIdx), but active step is \(currentStepIndex) ('\(currentStep.name)'). Step skipping/replay rejected."))
        }
        if let pStepID = proposal.stepID, pStepID != currentStep.id {
            return .rejected(.validationFailed(reason: "Step ID violation: proposal targeted step '\(pStepID)', but active step is '\(currentStep.id)'. Out-of-order execution rejected."))
        }

        // Deduplication against the active approval.
        let incomingFP = proposal.fingerprint
        if let existing = existingApproval, let existingFP = existing.fingerprint, existingFP == incomingFP {
            let reason: String
            switch existing.status {
            case .pending:
                reason = "An identical proposal is already pending supervisor approval for snapshot '\(proposal.snapshotID)'."
            case .approved:
                reason = "An identical proposal has already been approved and is awaiting dispatch for snapshot '\(proposal.snapshotID)'."
            case .executing:
                reason = "An identical proposal is currently executing for snapshot '\(proposal.snapshotID)'."
            case .succeeded:
                reason = "An identical action has already succeeded on snapshot '\(proposal.snapshotID)'. A fresh observation is required."
            case .failed:
                reason = "An identical proposal previously failed on snapshot '\(proposal.snapshotID)'. A fresh observation is required."
            case .expired:
                reason = "An identical proposal previously expired on snapshot '\(proposal.snapshotID)'."
            case .denied:
                reason = "An identical proposal was previously denied by supervisor on snapshot '\(proposal.snapshotID)'."
            }
            if existing.status == .pending || existing.status == .approved || existing.status == .executing || existing.status == .succeeded {
                return .rejected(.duplicateProposal(reason: reason))
            }
        }

        // Deduplication against actions already executed on this snapshot.
        if executedFingerprints.contains(incomingFP) {
            return .rejected(.duplicateProposal(reason: "Action with fingerprint '\(incomingFP.description)' has already executed on snapshot '\(proposal.snapshotID)'."))
        }

        // Policy validation against the active step.
        let validation = validator.validate(
            proposal: proposal,
            activeObservation: observation,
            activeStep: currentStep,
            activeStepIndex: currentStepIndex
        )
        switch validation {
        case .rejected(let reason):
            return .rejected(.validationFailed(reason: reason))
        case .valid(let safeScenario, let targetElement):
            for key in proposal.arguments.keys where Self.securitySensitiveKeys.contains(key) {
                return .rejected(.validationFailed(reason: "Security boundary violation: proposal attempted to supply or override trusted parameter '\(key)'. Identifiers are strictly system-controlled."))
            }

            // Execution arguments are rebuilt strictly from trusted validation state.
            var args: [String: AnyCodableValue] = [
                "snapshotID": .string(proposal.snapshotID),
                "elementID": .string(targetElement.id)
            ]
            for (k, v) in proposal.arguments where !Self.securitySensitiveKeys.contains(k) {
                args[k] = v
            }
            // Trusted scenario arguments are authoritative: a proposal can neither supply nor change them.
            for key in currentStep.trustedArguments.keys where proposal.arguments[key] != nil {
                return .rejected(.validationFailed(reason: "Security boundary violation: proposal attempted to supply trusted scenario argument '\(key)'."))
            }
            for (k, v) in currentStep.trustedArguments { args[k] = v }
            // A drag has two trusted ends. The source is the validated element; the destination comes only from the
            // step's trusted locator, resolved to exactly one element of this snapshot. The proposal supplies neither.
            if currentStep.toolName == "drag_and_drop" {
                for key in ["sourceElementID", "destinationElementID"] where proposal.arguments[key] != nil {
                    return .rejected(.validationFailed(reason: "Security boundary violation: proposal attempted to supply drag target '\(key)'."))
                }
                guard let destinationLocator = currentStep.destination else {
                    return .rejected(.validationFailed(reason: "Step '\(currentStep.id)' declares no trusted drag destination."))
                }
                let matches = (observation?.elements ?? []).filter { destinationLocator.matches(element: $0) }
                guard matches.count == 1, let destination = matches.first else {
                    return .rejected(.validationFailed(reason: "Trusted drag destination resolved to \(matches.count) elements in snapshot '\(proposal.snapshotID)'; exactly one is required."))
                }
                guard destination.id != targetElement.id else {
                    return .rejected(.validationFailed(reason: "Drag source and destination are the same element."))
                }
                args.removeValue(forKey: "elementID")
                args["sourceElementID"] = .string(targetElement.id)
                args["destinationElementID"] = .string(destination.id)
            }
            // A scroll names its target as a container; the element is still the validated one.
            if currentStep.toolName == "scroll", let element = args.removeValue(forKey: "elementID") { args["containerID"] = element }

            // Schema policy at admission: fields the tool does not declare are dropped, so they never reach the
            // approval request or the authorization; declared fields that are missing or malformed are refused
            // here, before a human is asked to approve. (At execution, unknown fields are rejected outright.)
            if let descriptor = ToolCatalog.descriptor(for: currentStep.toolName) {
                args = args.filter { descriptor.fieldNames.contains($0.key) }
                if let violation = ToolInputValidator().violation(of: descriptor, arguments: args) {
                    return .rejected(.validationFailed(reason: "Tool input rejected: \(violation)"))
                }
            }

            return .accepted(HITLApprovalRequest(
                actionName: "Scenario: \(safeScenario.name) [Step \(currentStepIndex + 1)/\(safeScenario.steps.count): \(currentStep.name)]",
                toolName: currentStep.toolName,
                boundTestCaseID: safeScenario.id,
                reason: proposal.reason,
                targetApp: observation?.bundleID ?? SimulatorTargetConfiguration.current.bundleID,
                snapshotID: proposal.snapshotID,
                arguments: args,
                targetLocator: TargetElementLocatorDetails(
                    elementID: targetElement.id, role: targetElement.role,
                    identifier: targetElement.identifier, label: targetElement.label, frame: targetElement.frame
                ),
                createdAt: now,
                expiresAt: ApprovalPolicy.expiryDate(from: now)
            ))
        }
    }
}
