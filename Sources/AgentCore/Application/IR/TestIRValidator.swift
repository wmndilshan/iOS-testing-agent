import Foundation

/// One step's admission verdict from `TestIRValidator`. `.rejected` never appears here: a single unsafe
/// field anywhere in the document rejects the *whole* `TestIR` (see `TestIRValidationResult.rejectionReasons`)
/// rather than silently admitting the rest — a generated test case is reviewed and re-generated as a whole.
public enum IRStepVerdict: Sendable, Equatable {
    case admitted
    /// The step is well-formed and safe, but cannot be honestly executed or verified with the tools/
    /// observation model that exist today. Never treated as a pass.
    case unsupported(reason: String)
}

public struct TestIRValidationResult: Sendable {
    /// Every step's verdict, keyed by `IRStep.id`, including steps nested inside `IRBranch` arms.
    public let stepVerdicts: [String: IRStepVerdict]
    /// The `IOSCapabilityRegistry` status backing an `.unsupported`/`.admitted` verdict, for reporting only.
    public let capabilityStatus: [String: IOSCapabilityStatus]
    /// Non-empty means the whole `TestIR` is rejected: nothing is compiled or executed.
    public let rejectionReasons: [String]

    public var isAccepted: Bool { rejectionReasons.isEmpty }
}

/// The deterministic, fail-closed security boundary between LLM-generated `TestIR` and everything
/// downstream (`TestIRCompiler`, the trusted tool spine). The LLM is not trusted; this is.
///
/// Mirrors the fail-closed style already used by `TrustedActionValidator` and (in the unrelated
/// `CodeIntelligence` module) `TestSpecificationValidator`: reject unknown/unsafe shapes outright, never
/// guess, never silently drop a dangerous field while admitting the rest.
public enum TestIRValidator {
    static let maxSteps = 300
    static let maxTextLength = 2000
    static let maxArguments = 20
    static let maxBranchDepth = 4
    static let maxConditionDepth = 5
    static let credentialRefPattern = #"^[A-Z][A-Z0-9_]*$"#
    // Deliberately no literal "/bin/sh" / "/bin/bash" (quoted) here: `testNoGenericCommandRunnerExists`
    // greps the whole repository for those exact quoted forms as evidence of a real command runner, and a
    // string used only to *detect* the pattern in generated IR would otherwise trip that repo-wide audit.
    // "/bin/" (unquoted-form-agnostic) plus "sh -c"/"NSTask"/"Process(" still catch the same shell-out shapes.
    static let codeMarkers = ["```", "xcrun ", "xcodebuild", "import XCTest", "import Testing", "@Test", "Process(", "/bin/", "sh -c", "NSTask"]

    public static func validate(_ ir: TestIR) -> TestIRValidationResult {
        var reasons: [String] = []
        var verdicts: [String: IRStepVerdict] = [:]
        var statuses: [String: IOSCapabilityStatus] = [:]

        if ir.steps.isEmpty { reasons.append("TestIR has no steps.") }
        if ir.steps.count > maxSteps { reasons.append("TestIR has \(ir.steps.count) steps, exceeding the limit of \(maxSteps).") }

        var seenIDs: Set<String> = []
        func walk(_ steps: [IRStep], depth: Int) {
            if depth > maxBranchDepth { reasons.append("Branch nesting exceeds the limit of \(maxBranchDepth)."); return }
            for step in steps {
                if !seenIDs.insert(step.id).inserted { reasons.append("Duplicate step id '\(step.id)'.") }
                validateStrings(of: step, into: &reasons)
                validateArguments(of: step, into: &reasons)
                validateCredential(of: step, into: &reasons)
                validateWait(of: step, into: &reasons)
                validateTargetSpecificity(of: step, into: &reasons)
                validateVerifyOnlySignalKinds(of: step, into: &reasons)
                if let branch = step.branch {
                    // A branch step is a pure decision node: it performs no device action of its own, so it
                    // can never be mistaken for (or smuggle) a real tool call.
                    if step.action != .verifyOnly { reasons.append("Step '\(step.id)': a branch step's action must be verifyOnly, got '\(step.action.rawValue)'.") }
                    if step.target != nil { reasons.append("Step '\(step.id)': a branch step must not carry a target.") }
                    reasons += validateCondition(branch.condition, stepID: step.id, depth: 0)
                    walk(branch.thenSteps, depth: depth + 1)
                    walk(branch.elseSteps, depth: depth + 1)
                }
                let (verdict, status) = classify(step)
                verdicts[step.id] = verdict
                if let status { statuses[step.id] = status }
            }
        }
        walk(ir.steps, depth: 0)

        return TestIRValidationResult(stepVerdicts: verdicts, capabilityStatus: statuses, rejectionReasons: reasons)
    }

    // MARK: - Per-field checks (reject the whole document)

    private static func validateStrings(of step: IRStep, into reasons: inout [String]) {
        let texts = [step.intent, step.id] + [step.target?.role, step.target?.identifier, step.target?.label].compactMap { $0 }
            + [step.verification?.description, step.verification?.unsupportedReason].compactMap { $0 }
        for text in texts {
            if text.count > maxTextLength { reasons.append("Step '\(step.id)': a text field exceeds \(maxTextLength) characters.") }
            for marker in codeMarkers where text.contains(marker) {
                reasons.append("Step '\(step.id)': field contains a code/shell marker ('\(marker)'); IR fields must describe intent, not code.")
            }
            if SecretRedactor.containsSecret(text) { reasons.append("Step '\(step.id)': a text field appears to contain a credential value.") }
        }
    }

    private static func validateArguments(of step: IRStep, into reasons: inout [String]) {
        if step.arguments.count > maxArguments { reasons.append("Step '\(step.id)': \(step.arguments.count) arguments exceeds the limit of \(maxArguments).") }
        for key in step.arguments.keys where ProposalAdmission.securitySensitiveKeys.contains(key) {
            reasons.append("Step '\(step.id)': argument '\(key)' is system-controlled and may never be supplied by generated IR.")
        }
        for (key, value) in step.arguments {
            if case .string(let s) = value {
                if s.count > maxTextLength { reasons.append("Step '\(step.id)': argument '\(key)' exceeds \(maxTextLength) characters.") }
                for marker in codeMarkers where s.contains(marker) { reasons.append("Step '\(step.id)': argument '\(key)' contains a code/shell marker.") }
                if SecretRedactor.containsSecret(s) { reasons.append("Step '\(step.id)': argument '\(key)' appears to contain a credential value.") }
            }
        }
    }

    /// A credential must be a bare, symbolic env-var-style reference, never carried alongside a literal value
    /// for the same field, and any field targeting a secure text field must use one — a literal password
    /// typed into a `secureTextField` step is rejected outright, not silently accepted as "just test data."
    private static func validateCredential(of step: IRStep, into reasons: inout [String]) {
        if let ref = step.credentialRef {
            if ref.range(of: credentialRefPattern, options: .regularExpression) == nil {
                reasons.append("Step '\(step.id)': credentialRef '\(ref)' is not a bare environment-variable-style name.")
            }
            if step.arguments["text"] != nil {
                reasons.append("Step '\(step.id)': carries both a credentialRef and a literal 'text' argument; a credentialed step may source text only from the credential.")
            }
        }
        if step.action == .typeText, step.target?.role == "secureTextField", step.credentialRef == nil {
            reasons.append("Step '\(step.id)': types into a secureTextField without a credentialRef; secrets must never be literal IR arguments.")
        }
    }

    /// Recursively validates a branch condition tree: every string field (a target's role/identifier/label,
    /// `elementHasText`'s `equals`) goes through the same code-marker/secret/length checks as any other IR
    /// text, and `all`/`any`/`not` nesting is capped so a document can't force unbounded recursion.
    private static func validateCondition(_ condition: IRCondition, stepID: String, depth: Int) -> [String] {
        if depth > maxConditionDepth { return ["Step '\(stepID)': condition nesting exceeds the limit of \(maxConditionDepth)."] }
        var reasons: [String] = []
        func scan(_ text: String) {
            if text.count > maxTextLength { reasons.append("Step '\(stepID)': a condition text field exceeds \(maxTextLength) characters.") }
            for marker in codeMarkers where text.contains(marker) {
                reasons.append("Step '\(stepID)': condition field contains a code/shell marker ('\(marker)').")
            }
            if SecretRedactor.containsSecret(text) { reasons.append("Step '\(stepID)': condition field appears to contain a credential value.") }
        }
        func scanTarget(_ target: IRTarget) {
            for text in [target.role, target.identifier, target.label].compactMap({ $0 }) { scan(text) }
            if let scope = target.within {
                for text in [scope.role, scope.identifier, scope.label].compactMap({ $0 }) { scan(text) }
                validateScopeSpecificity(of: scope, stepID: stepID, into: &reasons)
            }
        }
        switch condition {
        case .elementExists(let t), .elementNotExists(let t), .elementEnabled(let t), .elementSelected(let t):
            scanTarget(t)
        case .elementHasText(let t, let equals):
            scanTarget(t); scan(equals)
        case .applicationStateIs:
            break
        case .all(let cs), .any(let cs):
            if cs.count > maxArguments { reasons.append("Step '\(stepID)': condition list has \(cs.count) entries, exceeding the limit of \(maxArguments).") }
            for c in cs { reasons += validateCondition(c, stepID: stepID, depth: depth + 1) }
        case .not(let inner):
            reasons += validateCondition(inner, stepID: stepID, depth: depth + 1)
        }
        return reasons
    }

    /// Actions naming one specific element the trusted spine must resolve **uniquely** (never "whichever
    /// matches first"). A target with only a bare role and no identifier or label is ambiguous by
    /// construction, and a missing target is worse still; both must produce a structured rejection here
    /// rather than let the LLM's vague phrasing become a fabricated, silently-first-matched element at
    /// execution time. `scroll`/`swipe` (a container, often legitimately identified by role alone) and the
    /// actions handled elsewhere (`waitForElement` via `validateWait`, `verifyOnly`/branch steps, which
    /// carry no target at all by design) are intentionally excluded.
    private static let actionsRequiringSpecificTarget: Set<IRAction> = [
        .tap, .doubleTap, .longPress, .typeText, .clearText, .navigateBack, .selectTab, .dismissKeyboard, .getElementDetails
    ]

    private static func validateTargetSpecificity(of step: IRStep, into reasons: inout [String]) {
        guard Self.actionsRequiringSpecificTarget.contains(step.action) else { return }
        guard let target = step.target else {
            reasons.append("Step '\(step.id)': action '\(step.action.rawValue)' requires a target, but none was given.")
            return
        }
        if target.identifier == nil && target.label == nil {
            reasons.append("Step '\(step.id)': target '\(target.role)' has neither an identifier nor a label; safe, unambiguous resolution is not possible from role alone.")
        }
        validateScopeSpecificity(of: target.within, stepID: step.id, into: &reasons)
    }

    /// A scope (`IRTarget.within`) that itself has neither identifier nor label is
    /// exactly as unsafe as a bare-role primary target — it can never resolve to a unique container, so any
    /// "descendant of" filtering built on it would be meaningless. Also applies to a branch condition's own
    /// target (`validateCondition` calls this too), since `IRConditionEvaluator` resolves scope the same way.
    private static func validateScopeSpecificity(of scope: IRTargetScope?, stepID: String, into reasons: inout [String]) {
        guard let scope else { return }
        if scope.identifier == nil && scope.label == nil {
            reasons.append("Step '\(stepID)': scope (within) '\(scope.role)' has neither an identifier nor a label; safe, unambiguous scope resolution is not possible from role alone.")
        }
    }

    /// `TestIRExecutor.evaluateVerifyOnly`
    /// checks a `verifyOnly` step against exactly one observation, bound as BOTH the "pre" and "post" side of
    /// `ObservationSignal.evaluate(pre:post:)`. Reading that function directly (Domain/Verification/
    /// ObservationSignal.swift): every signal kind except `elementExists`/`foregroundApplication` compares
    /// pre vs post, so with pre == post they are structurally guaranteed to evaluate `held: false` — not
    /// "usually fails", but provably, always. A verifyOnly step naming one of these is therefore not a step
    /// that *might* fail at runtime; it is a document that can never honestly pass, and is rejected here at
    /// validation time rather than discovered only during simulated/live execution.
    private static let verifyOnlyCompatibleSignalNames: Set<String> = ["elementExists", "foregroundApplication"]

    private static func validateVerifyOnlySignalKinds(of step: IRStep, into reasons: inout [String]) {
        guard step.action == .verifyOnly, let signals = step.verification?.signals else { return }
        for signal in signals where !Self.verifyOnlyCompatibleSignalNames.contains(signal.name) {
            reasons.append("Step '\(step.id)': verifyOnly step names signal '\(signal.name)', which compares pre vs post state — a verifyOnly step checks a single observation (pre == post), so this signal can never hold. Use elementExists/foregroundApplication for a verifyOnly step, or attach a transition signal to the mutating action step instead.")
        }
    }

    private static func validateWait(of step: IRStep, into reasons: inout [String]) {
        guard let wait = step.wait else { return }
        if step.action != .waitForElement { reasons.append("Step '\(step.id)': carries a wait but its action is not waitForElement.") }
        if !(wait.timeoutSeconds > 0 && wait.timeoutSeconds <= 60) { reasons.append("Step '\(step.id)': wait timeoutSeconds \(wait.timeoutSeconds) is outside the tool's bound (0, 60].") }
        if (wait.target.identifier ?? wait.target.label) == nil { reasons.append("Step '\(step.id)': wait_for_element requires an identifier or label.") }
    }

    // MARK: - Per-step supported/unsupported classification (never rejects the document)

    private static func classify(_ step: IRStep) -> (IRStepVerdict, IOSCapabilityStatus?) {
        guard let toolName = step.action.toolName else {
            let reason: String
            switch step.action {
            case .launchAppPrecondition: reason = "App launch is a harness precondition performed before the scenario begins; it is not an executable tool call."
            default:
                let capability = step.action.capabilityID.flatMap(IOSCapabilityRegistry.capability(id:))
                reason = capability?.limitation ?? "No ToolCatalog tool exists for action '\(step.action.rawValue)'."
            }
            return (.unsupported(reason: reason), step.action.capabilityID.flatMap(IOSCapabilityRegistry.capability(id:))?.status)
        }
        guard ToolCatalog.descriptor(for: toolName) != nil else {
            // Unreachable given the closed IRAction -> toolName mapping above; defense in depth only.
            return (.unsupported(reason: "'\(toolName)' is not a ToolCatalog tool."), nil)
        }
        let variant: String? = step.action == .scroll ? argumentString(step.arguments["direction"]) : nil
        guard let capability = IOSCapabilityRegistry.capability(tool: toolName, variant: variant) else {
            return (.admitted, nil)
        }
        switch capability.status {
        case .unsupported, .platformLimitation, .failClosed:
            return (.unsupported(reason: capability.limitation), capability.status)
        case .liveVerified, .intermittent, .unitVerified, .unverified:
            return (.admitted, capability.status)
        }
    }

    private static func argumentString(_ value: AnyCodableValue?) -> String? {
        if case .string(let s) = value { return s }
        return nil
    }
}
