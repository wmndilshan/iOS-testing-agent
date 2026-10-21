import Foundation

// MARK: - IRAction

/// The closed set of semantic actions a Test IR step may name. Each case maps 1:1 to an existing
/// `ToolCatalog` tool (never invented), to an explicitly-modeled-but-never-executable capability (so an
/// AIO concept the platform cannot safely express still decodes, and is rejected honestly by
/// `TestIRValidator` rather than silently dropped), or to `verifyOnly` (no tool call; an assertion against
/// the current observation). This is not one case per English phrase: composite AIO steps ("create a
/// collection") are represented as a *sequence* of `IRStep`s using these primitives, not a new case.
public enum IRAction: String, Codable, Sendable, Equatable, CaseIterable {
    /// AIO instructions of the form "launch the app". Launching the app under test is a harness/CLI
    /// precondition performed before any scenario begins, not a device tool call; this case exists only so
    /// such an AIO step decodes and is reported honestly (`toolName == nil` -> always `.unsupported`).
    case launchAppPrecondition
    /// AIO instructions of the form "handle the system permission dialog". Maps to the `system_alert`
    /// capability, which `IOSCapabilityRegistry` marks `PLATFORM_LIMITATION` (SpringBoard, not the app under
    /// test) — always `.unsupported`.
    case systemDialogDismissal
    case tap
    case doubleTap
    case longPress
    case swipe
    case dragAndDrop
    case typeText
    case clearText
    case navigateBack
    case selectTab
    case dismissKeyboard
    case scroll
    case waitForElement
    case captureScreenshot
    case inspectElements
    /// Reads one already-resolved element's trusted facts (no device call: the same snapshot the proposal
    /// was validated against).
    case getElementDetails
    /// Reads the application's current runtime state (running foreground/background/not running).
    case appState
    /// No tool call: verify the current (freshly captured, read-only) observation only.
    case verifyOnly
    /// Explicitly modeled but never executable (`IOSCapabilityRegistry` = `UNSUPPORTED`); kept as a named
    /// case (rather than an unknown string, which would fail to decode) so the validator's rejection is a
    /// reported, honest `.unsupported` verdict instead of a generation-time decode crash.
    case pullToRefresh
    /// Deliberately unsupported by policy (`IOSCapabilityRegistry` = `UNSUPPORTED`, "no raw coordinate
    /// execution"). An IR can never target a coordinate through any other case: `IRTarget` has no x/y fields.
    case coordinateTap

    /// The existing `ToolCatalog` tool this action executes as, or `nil` when no tool exists (the step can
    /// never be admitted; it is reported `.unsupported`, never silently substituted).
    public var toolName: String? {
        switch self {
        case .launchAppPrecondition, .systemDialogDismissal, .pullToRefresh, .coordinateTap: return nil
        case .tap: return "tap_element"
        case .doubleTap: return "double_tap_element"
        case .longPress: return "long_press_element"
        case .swipe: return "swipe"
        case .dragAndDrop: return "drag_and_drop"
        case .typeText: return "type_text"
        case .clearText: return "clear_text"
        case .navigateBack: return "navigate_back"
        case .selectTab: return "select_tab"
        case .dismissKeyboard: return "dismiss_keyboard"
        case .scroll: return "scroll"
        case .waitForElement: return "wait_for_element"
        case .captureScreenshot: return "capture_screenshot"
        case .inspectElements: return "inspect_elements"
        case .getElementDetails: return "get_element_details"
        case .appState: return "get_app_state"
        case .verifyOnly: return "get_accessibility_tree"
        }
    }

    /// The `IOSCapabilityRegistry` capability id used to look up honest, already-documented status/limitation
    /// text. `scroll`'s capability is variant-specific (direction) and is resolved separately by the caller.
    public var capabilityID: String? {
        switch self {
        case .systemDialogDismissal: return "system_alert"
        case .pullToRefresh: return "pull_to_refresh"
        case .coordinateTap: return "coordinate_tap"
        case .tap: return "tap"
        case .doubleTap: return "double_tap"
        case .longPress: return "long_press"
        case .swipe: return "swipe"
        case .dragAndDrop: return "drag_and_drop"
        case .typeText: return "type_text"
        case .clearText: return "clear_text"
        case .navigateBack: return "back_navigation"
        case .selectTab: return "tab_selection"
        case .dismissKeyboard: return "keyboard_dismissal"
        case .waitForElement: return "wait_for_element"
        case .captureScreenshot: return "screenshot"
        case .inspectElements: return "inspect_elements"
        case .getElementDetails: return "element_details"
        case .appState: return "app_state"
        case .scroll, .verifyOnly, .launchAppPrecondition: return nil
        }
    }
}

// MARK: - IRTarget

/// Exactly `ScenarioLocator`'s shape (role required, identifier/label optional so an LLM extracting from
/// English text can resolve a target by role+label alone). No coordinate fields exist anywhere in this type.
public struct IRTarget: Codable, Sendable, Equatable {
    public let role: String
    public let identifier: String?
    public let label: String?
    /// An optional containing element this target must be scoped within (e.g. "the
    /// ALPHA row *inside the Collection items container*"). Resolved deterministically at CONDITION-evaluation
    /// time only, using the real, already-populated `UIElementSnapshot.parentID` ancestor chain (see
    /// `IRConditionEvaluator`) — it never changes what gets compiled into a device-action's `ScenarioLocator`
    /// (`TestIRCompiler`/`ScenarioLocator` are unchanged; the trusted spine's own admission/dispatch matching
    /// is untouched). `IRTargetScope` deliberately cannot itself carry a further `within`, capping containment
    /// at exactly one level — both to avoid a self-recursive value type and because open-ended containment
    /// chains add complexity without a clearly safe execution semantic.
    public let within: IRTargetScope?

    public init(role: String, identifier: String? = nil, label: String? = nil, within: IRTargetScope? = nil) {
        self.role = role
        self.identifier = identifier
        self.label = label
        self.within = within
    }

    public var locator: ScenarioLocator { ScenarioLocator(role: role, identifier: identifier, label: label) }
}

/// A one-level-only container reference for `IRTarget.within` — see that field's doc comment for the full
/// rationale. Structurally identical to `IRTarget` minus the ability to nest further.
public struct IRTargetScope: Codable, Sendable, Equatable {
    public let role: String
    public let identifier: String?
    public let label: String?

    public init(role: String, identifier: String? = nil, label: String? = nil) {
        self.role = role
        self.identifier = identifier
        self.label = label
    }

    public var asTarget: IRTarget { IRTarget(role: role, identifier: identifier, label: label) }
}

// MARK: - IRVerification

/// Reuses the existing verification vocabulary directly (`ScenarioExpectedElement`, `ObservationSignal`) —
/// no parallel assertion language. `unsupportedReason`, when set, means the AIO step's expected result names
/// a property the current observation model cannot honestly prove (e.g. "column is sticky"); the step is
/// still generated and validated, but reported `UNSUPPORTED_BY_CURRENT_OBSERVATION`, never marked as passing.
public struct IRVerification: Codable, Sendable, Equatable {
    public let description: String
    public let requiredElements: [ScenarioExpectedElement]
    public let forbiddenElements: [ScenarioExpectedElement]
    public let signals: [ObservationSignal]
    public let unsupportedReason: String?

    public init(description: String, requiredElements: [ScenarioExpectedElement] = [], forbiddenElements: [ScenarioExpectedElement] = [],
                signals: [ObservationSignal] = [], unsupportedReason: String? = nil) {
        self.description = description
        self.requiredElements = requiredElements
        self.forbiddenElements = forbiddenElements
        self.signals = signals
        self.unsupportedReason = unsupportedReason
    }
}

// MARK: - IRWait

/// Compiles only to `wait_for_element`; an IR can never express a raw sleep.
public struct IRWait: Codable, Sendable, Equatable {
    public let target: IRTarget
    public let timeoutSeconds: Double

    public init(target: IRTarget, timeoutSeconds: Double) {
        self.target = target
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - IRBranch

/// Conditional step selection. The condition is a deterministic, observation-based predicate tree
/// (`IRCondition`) only — the LLM proposes the shape of the branch, but which arm actually runs is decided
/// at execution time by `TestIRExecutor.evaluateBranch` from a fresh observation, never by the LLM and never
/// by an execution-time re-ask. A step carrying a `branch` is a pure decision node (`TestIRValidator`
/// requires `action == .verifyOnly` and `target == nil` on it) — it performs no device action of its own.
public struct IRBranch: Codable, Sendable, Equatable {
    public let condition: IRCondition
    public let thenSteps: [IRStep]
    public let elseSteps: [IRStep]

    public init(condition: IRCondition, thenSteps: [IRStep], elseSteps: [IRStep]) {
        self.condition = condition
        self.thenSteps = thenSteps
        self.elseSteps = elseSteps
    }
}

// MARK: - IRStep

public struct IRStep: Codable, Sendable, Equatable {
    public let id: String
    /// Traceability back to the originating AIO step (e.g. `7` for DEMO-TC-872 step 7). Several `IRStep`s may
    /// share the same `sourceStepNumber` when one AIO step decomposes into a sequence of primitives.
    public let sourceStepNumber: Int
    /// Human-readable restatement of what this step does, for the mapping-table report; never executed.
    public let intent: String
    public let action: IRAction
    public let target: IRTarget?
    /// Non-secret arguments only (e.g. a scroll direction, search text). Never a credential value.
    public let arguments: [String: AnyCodableValue]
    /// A symbolic reference to a credential (e.g. `"TEST_USER_PASSWORD"`), resolved to an environment
    /// variable value only by `TestIRCompiler`, at the last trusted step, never earlier and never logged.
    /// The literal secret value never appears anywhere in a `TestIR` document.
    public let credentialRef: String?
    public let wait: IRWait?
    public let branch: IRBranch?
    public let verification: IRVerification?

    public init(id: String, sourceStepNumber: Int, intent: String, action: IRAction, target: IRTarget? = nil,
                arguments: [String: AnyCodableValue] = [:], credentialRef: String? = nil, wait: IRWait? = nil,
                branch: IRBranch? = nil, verification: IRVerification? = nil) {
        self.id = id
        self.sourceStepNumber = sourceStepNumber
        self.intent = intent
        self.action = action
        self.target = target
        self.arguments = arguments
        self.credentialRef = credentialRef
        self.wait = wait
        self.branch = branch
        self.verification = verification
    }
}

// MARK: - TestIR

/// The root, LLM-generated (and human-reviewable) document. Pure data: no code, no shell, no coordinates —
/// enforced by the closed types above, not by convention. `TestIRValidator` is the security boundary between
/// this and everything downstream; `TestIRCompiler` is the only code that turns it into `ScenarioStep`s.
public struct TestIR: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// The AIO test's own key (e.g. `DEMO-TC-872`), for traceability only — never used as scenario
    /// authorization identity by the validator/compiler/executor.
    public let testKey: String
    public let title: String
    public let steps: [IRStep]

    public init(testKey: String, title: String, steps: [IRStep]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.testKey = testKey
        self.title = title
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, testKey, title, steps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported TestIR schemaVersion \(version)")
        }
        self.schemaVersion = version
        self.testKey = try c.decode(String.self, forKey: .testKey)
        self.title = try c.decode(String.self, forKey: .title)
        self.steps = try c.decode([IRStep].self, forKey: .steps)
    }

    /// Strict decode: unknown top-level fields and a schema-version mismatch are refused outright (the same
    /// discipline as `GeneratedTestExecutionRequest.decode`). Any unrecognized `IRAction` string, or a
    /// required field missing anywhere in the tree, already fails Swift's `Decodable` synthesis, so a
    /// generated-then-tampered document such as `{"action": "run_shell"}` never reaches a `TestIR` value.
    public static func decode(_ data: Data) -> TestIR? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Self.fieldNames,
              let ir = try? JSONDecoder().decode(TestIR.self, from: data) else { return nil }
        return ir
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    static let fieldNames: Set<String> = ["schemaVersion", "testKey", "title", "steps"]
}
