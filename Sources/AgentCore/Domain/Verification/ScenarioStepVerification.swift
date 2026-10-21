import Foundation

/// Defines deterministic, trusted verification criteria for a scenario step.
/// Verified strictly against a fresh post-execution observation.
public struct ScenarioStepVerification: Codable, Sendable, Equatable {
    public let description: String
    public let requiredElements: [ScenarioExpectedElement]
    public let forbiddenElements: [ScenarioExpectedElement]

    public init(
        description: String,
        requiredElements: [ScenarioExpectedElement] = [],
        forbiddenElements: [ScenarioExpectedElement] = []
    ) {
        self.description = description
        self.requiredElements = requiredElements
        self.forbiddenElements = forbiddenElements
    }

    /// Evaluates the criteria deterministically against a fresh observation.
    public func verify(in observation: Observation) -> ScenarioVerificationResult {
        // 1. All required elements must be present and pass validation
        for req in requiredElements {
            guard let matched = observation.elements.first(where: { req.matches(element: $0) }) else {
                let identifierDesc = req.identifier ?? req.label ?? req.role
                return ScenarioVerificationResult(
                    verified: false,
                    reason: "Required element '\(identifierDesc)' was not found in post-execution snapshot '\(observation.snapshotID)'."
                )
            }
            let (valid, details) = req.validate(against: matched)
            guard valid else {
                let identifierDesc = req.identifier ?? req.label ?? req.role
                return ScenarioVerificationResult(
                    verified: false,
                    reason: "Required element '\(identifierDesc)' failed validation: \(details)"
                )
            }
        }

        // 2. All forbidden elements must be strictly absent
        for forb in forbiddenElements {
            if observation.elements.contains(where: { forb.matches(element: $0) }) {
                let identifierDesc = forb.identifier ?? forb.label ?? forb.role
                return ScenarioVerificationResult(
                    verified: false,
                    reason: "Forbidden element '\(identifierDesc)' is present in post-execution snapshot '\(observation.snapshotID)'."
                )
            }
        }

        return ScenarioVerificationResult(
            verified: true,
            reason: "Verification passed: \(description)"
        )
    }
}
