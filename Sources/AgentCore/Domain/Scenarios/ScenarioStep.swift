import Foundation

public struct ScenarioStep: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let toolName: String
    public let locator: ScenarioLocator
    public let requiresApproval: Bool
    public let verification: ScenarioStepVerification?
    /// Arguments fixed by the trusted scenario (a direction, a duration, fixture text). They are the only source of
    /// these values: a proposal cannot supply, change or add them, and they never reach an LLM prompt.
    public let trustedArguments: [String: AnyCodableValue]
    /// Trusted second target (drag destination). The step owns both ends of a drag: the source is the validated element
    /// the proposal names, the destination is resolved from this locator against the fresh snapshot. A proposal can
    /// never supply or replace it.
    public let destination: ScenarioLocator?
    /// The state that must hold on the fresh pre-action observation before anything is proposed or approved (trusted data).
    public let precondition: ScenarioStepVerification?
    /// Typed transition signals that must all hold between the fresh pre-action and fresh post-action observations
    /// (in addition to `verification`). Trusted catalog data.
    public let signals: [ObservationSignal]

    public init(
        id: String,
        name: String,
        description: String,
        toolName: String = "tap_element",
        locator: ScenarioLocator,
        requiresApproval: Bool = true,
        verification: ScenarioStepVerification? = nil,
        trustedArguments: [String: AnyCodableValue] = [:],
        destination: ScenarioLocator? = nil,
        precondition: ScenarioStepVerification? = nil,
        signals: [ObservationSignal] = []
    ) {
        self.precondition = precondition
        self.signals = signals
        self.id = id
        self.name = name
        self.description = description
        self.toolName = toolName
        self.locator = locator
        self.requiresApproval = requiresApproval
        self.verification = verification
        self.trustedArguments = trustedArguments
        self.destination = destination
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, toolName, locator, requiresApproval, verification, destination, precondition, signals
        // Deliberately not encoded: trusted arguments (which may include text to type) never reach a stored record.
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  description: try c.decode(String.self, forKey: .description), toolName: try c.decode(String.self, forKey: .toolName),
                  locator: try c.decode(ScenarioLocator.self, forKey: .locator), requiresApproval: try c.decode(Bool.self, forKey: .requiresApproval),
                  verification: try c.decodeIfPresent(ScenarioStepVerification.self, forKey: .verification),
                  destination: try c.decodeIfPresent(ScenarioLocator.self, forKey: .destination),
                  precondition: try c.decodeIfPresent(ScenarioStepVerification.self, forKey: .precondition),
                  signals: try c.decodeIfPresent([ObservationSignal].self, forKey: .signals) ?? [])
    }
}
