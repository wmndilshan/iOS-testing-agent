import Foundation

/// Deterministic, no-LLM lowering of one validated `IRStep` into the same `ScenarioStep` shape the static
/// `ScenarioCatalog` entries use. Mirrors `CodeIntelligence.InstructionCompiler` (spec -> instruction),
/// applied to this different domain: it never invents a tool, never widens a schema, and resolves a
/// `credentialRef` to its environment-variable value only here — the one place a secret enters trusted
/// arguments, which `ScenarioStep` already excludes from `Codable` encoding and which never reaches an LLM.
///
/// Only called for steps `TestIRValidator` marked `.admitted`; the caller (`TestIRExecutor`) never compiles
/// an `.unsupported` step.
public enum TestIRCompiler {

    public struct CompiledStep: Sendable {
        public let irStepID: String
        public let sourceStepNumber: Int
        public let scenarioStep: ScenarioStep
    }

    public enum CompileOutcome: Sendable {
        case compiled(CompiledStep)
        case skipped(irStepID: String, reason: String)
    }

    /// - Parameter credentials: where a `credentialRef` resolves to a value. Defaults to the real process
    ///   environment; tests inject a fixed dictionary so no real secret needs to exist on the test machine.
    public static func compile(_ step: IRStep, credentials: [String: String] = ProcessInfo.processInfo.environment) -> CompileOutcome {
        guard let toolName = step.action.toolName else {
            return .skipped(irStepID: step.id, reason: "no ToolCatalog tool for action '\(step.action.rawValue)'")
        }
        guard let descriptor = ToolCatalog.descriptor(for: toolName) else {
            return .skipped(irStepID: step.id, reason: "'\(toolName)' is not a ToolCatalog tool")
        }

        var trustedArguments: [String: AnyCodableValue] = [:]
        let locator: ScenarioLocator
        if step.action == .waitForElement, let wait = step.wait {
            locator = wait.target.locator
            trustedArguments["identifier"] = .string(wait.target.identifier ?? wait.target.label ?? "")
            trustedArguments["timeoutSeconds"] = .double(wait.timeoutSeconds)
        } else if let target = step.target {
            locator = target.locator
        } else {
            locator = ScenarioLocator(role: "application")
        }
        // Only fields the tool actually declares; an unknown argument is dropped here rather than reaching
        // approval (ToolInputValidator would refuse it again at admission regardless — defense in depth).
        for (key, value) in step.arguments where descriptor.fieldNames.contains(key) { trustedArguments[key] = value }

        if let ref = step.credentialRef {
            guard let secret = credentials[ref], !secret.isEmpty else {
                return .skipped(irStepID: step.id, reason: "credentialRef '\(ref)' has no value in the trusted environment")
            }
            trustedArguments["text"] = .string(secret)
        }

        let verification = step.verification.map {
            ScenarioStepVerification(description: $0.description, requiredElements: $0.requiredElements, forbiddenElements: $0.forbiddenElements)
        }

        let scenarioStep = ScenarioStep(
            id: step.id,
            name: step.intent,
            description: step.intent,
            toolName: toolName,
            locator: locator,
            requiresApproval: descriptor.requiresApproval,
            verification: verification,
            trustedArguments: trustedArguments,
            destination: step.dragDestination?.locator,
            precondition: nil,
            signals: step.verification?.signals ?? []
        )
        return .compiled(CompiledStep(irStepID: step.id, sourceStepNumber: step.sourceStepNumber, scenarioStep: scenarioStep))
    }
}
