import Foundation

public struct SafeScenario: Codable, Sendable, Identifiable {
    /// Tools a scenario with `changesUIState == false` may run. It is a closed list in the domain model, so the
    /// read-only policy does not depend on the application layer; a test asserts every name here is classified
    /// `.readOnly` by the trusted `ToolCatalog`, and that no mutating tool can appear.
    public static let readOnlyScenarioTools: Set<String> = ["inspect_elements", "capture_screenshot", "wait_for_element", "get_app_state", "get_element_details", "get_accessibility_tree"]

    public let id: String
    public let name: String
    public let purpose: String
    public let initialStateRequirement: String
    public let expectedPostActionState: String
    public let changesUIState: Bool
    public let actionStep: ScenarioStep
    public let teardownStep: ScenarioStep?
    public let expectedElements: [ScenarioExpectedElement]
    public var phase: ScenarioPhase
    /// An ordered N-step sequence (used by `TestIRExecutor` for a compiled `TestIR`), when set via
    /// `init(id:name:purpose:...:steps:...)`. `nil` for every scenario built the original way, so `.steps`
    /// falls back to the existing `[actionStep, teardownStep?]` pair unchanged.
    private let explicitSteps: [ScenarioStep]?

    public var steps: [ScenarioStep] {
        if let explicitSteps { return explicitSteps }
        if let teardown = teardownStep {
            return [actionStep, teardown]
        }
        return [actionStep]
    }

    public init(
        id: String,
        name: String,
        purpose: String,
        initialStateRequirement: String,
        expectedPostActionState: String,
        changesUIState: Bool,
        actionStep: ScenarioStep,
        teardownStep: ScenarioStep? = nil,
        expectedElements: [ScenarioExpectedElement] = [],
        phase: ScenarioPhase = .ready
    ) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.initialStateRequirement = initialStateRequirement
        self.expectedPostActionState = expectedPostActionState
        self.changesUIState = changesUIState
        self.actionStep = actionStep
        self.teardownStep = teardownStep
        self.expectedElements = expectedElements
        self.phase = phase
        self.explicitSteps = nil
    }

    /// Builds a scenario from an explicit, ordered N-step sequence instead of an action/teardown pair.
    /// `actionStep`/`teardownStep` are kept populated (first/second of `steps`) only so any code still
    /// reading them directly (never security-relevant: `TrustedActionValidator`/`ProposalAdmission` read
    /// `.steps` generically) sees a sensible value; `.steps` itself always returns the full `steps` array.
    public init(
        id: String,
        name: String,
        purpose: String,
        initialStateRequirement: String,
        expectedPostActionState: String,
        changesUIState: Bool,
        steps: [ScenarioStep],
        expectedElements: [ScenarioExpectedElement] = [],
        phase: ScenarioPhase = .ready
    ) {
        precondition(!steps.isEmpty, "SafeScenario requires at least one step")
        self.id = id
        self.name = name
        self.purpose = purpose
        self.initialStateRequirement = initialStateRequirement
        self.expectedPostActionState = expectedPostActionState
        self.changesUIState = changesUIState
        self.actionStep = steps[0]
        self.teardownStep = steps.count > 1 ? steps[1] : nil
        self.expectedElements = expectedElements
        self.phase = phase
        self.explicitSteps = steps
    }
}
