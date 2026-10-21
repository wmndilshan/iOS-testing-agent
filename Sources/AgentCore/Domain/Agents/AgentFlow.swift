import Foundation

/// How the team of agents is set up: which specialists take part, which model tier each uses, and how much each may do.
/// The prompts and tools stay fixed; the default flow is exactly the team the app always had.
public struct AgentFlow: Codable, Equatable, Sendable, Identifiable {
    public enum Tier: String, Codable, CaseIterable, Sendable, Identifiable {
        case fast, strong
        public var id: String { rawValue }
        public var title: String { self == .fast ? "Fast" : "Strong" }
    }

    public struct Member: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var tier: Tier
        public var maxTurns: Int
        public var maxToolCalls: Int

        public init(enabled: Bool = true, tier: Tier, maxTurns: Int, maxToolCalls: Int = 40) {
            self.enabled = enabled
            self.tier = tier
            self.maxTurns = maxTurns
            self.maxToolCalls = maxToolCalls
        }
    }

    /// The specialists, in the order they normally work.
    public enum Role: String, CaseIterable, Sendable, Identifiable {
        case analyst = "RepoAnalyst", author = "CaseAuthor", runner = "Runner", validator = "Validator", device = "DeviceOperator"
        public var id: String { rawValue }
        public var summary: String {
            switch self {
            case .analyst: "Reads the repository for screens, labels and the bundle id"
            case .author: "Writes the test case file"
            case .runner: "Runs a saved case on the simulator, after your approval"
            case .validator: "Judges the run against the scenario"
            case .device: "Controls the simulator directly: looks at the screen, taps, opens links, presses buttons, grants permissions"
            }
        }
    }

    public var name: String
    public var analyst: Member
    public var author: Member
    public var runner: Member
    public var validator: Member
    /// Off in every preset except "Device control": the default team is unchanged.
    public var device: Member
    public var orchestratorMaxTurns: Int
    public var id: String { name }

    public init(name: String, analyst: Member, author: Member, runner: Member, validator: Member, device: Member = AgentFlow.deviceOff, orchestratorMaxTurns: Int = 14) {
        self.name = name
        self.device = device
        self.analyst = analyst
        self.author = author
        self.runner = runner
        self.validator = validator
        self.orchestratorMaxTurns = orchestratorMaxTurns
    }

    public subscript(role: Role) -> Member {
        get {
            switch role {
            case .analyst: analyst
            case .author: author
            case .runner: runner
            case .validator: validator
            case .device: device
            }
        }
        set {
            switch role {
            case .analyst: analyst = newValue
            case .author: author = newValue
            case .runner: runner = newValue
            case .validator: validator = newValue
            case .device: device = newValue
            }
        }
    }

    public var enabledRoles: [Role] { Role.allCases.filter { self[$0].enabled } }
    /// Names shown as the team: the orchestrator and every enabled specialist.
    public var teamNames: [String] { ["Orchestrator"] + enabledRoles.map(\.rawValue) }
    /// A flow needs at least one specialist, or the orchestrator has nobody to delegate to.
    public var isUsable: Bool { !enabledRoles.isEmpty }

    private enum CodingKeys: String, CodingKey { case name, analyst, author, runner, validator, device, orchestratorMaxTurns }

    /// A flow saved before the device role existed has no `device` member: it reads as off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        analyst = try container.decode(Member.self, forKey: .analyst)
        author = try container.decode(Member.self, forKey: .author)
        runner = try container.decode(Member.self, forKey: .runner)
        validator = try container.decode(Member.self, forKey: .validator)
        device = try container.decodeIfPresent(Member.self, forKey: .device) ?? Self.deviceOff
        orchestratorMaxTurns = try container.decodeIfPresent(Int.self, forKey: .orchestratorMaxTurns) ?? 14
    }

    // MARK: Presets

    private static let analystDefault = Member(tier: .fast, maxTurns: 7, maxToolCalls: 18)
    private static let authorDefault = Member(tier: .strong, maxTurns: 8)
    private static let runnerDefault = Member(tier: .fast, maxTurns: 4)
    private static let validatorDefault = Member(tier: .strong, maxTurns: 6)
    public static let deviceOff = Member(enabled: false, tier: .fast, maxTurns: 14, maxToolCalls: 40)
    private static let deviceOn = Member(tier: .fast, maxTurns: 14, maxToolCalls: 40)

    /// Analyst, author, runner, validator: the team as it always was.
    public static let full = AgentFlow(name: "Full team", analyst: analystDefault, author: authorDefault, runner: runnerDefault, validator: validatorDefault)

    /// Writes a case from the scenario and the repository, and stops there. Nothing is run.
    public static let authorOnly: AgentFlow = {
        var flow = full
        flow.name = "Write cases only"
        flow.runner.enabled = false
        flow.validator.enabled = false
        return flow
    }()

    /// Runs a case that already exists and judges the result.
    public static let runExisting: AgentFlow = {
        var flow = full
        flow.name = "Run existing case"
        flow.analyst.enabled = false
        flow.author.enabled = false
        return flow
    }()

    /// Answers questions about the repository.
    public static let repositoryQuestions: AgentFlow = {
        var flow = full
        flow.name = "Repository questions"
        flow.author.enabled = false
        flow.runner.enabled = false
        flow.validator.enabled = false
        return flow
    }()

    /// Controls the simulator directly; no repository, case or run work.
    public static let deviceControl: AgentFlow = {
        var flow = full
        flow.name = "Device control"
        flow.analyst.enabled = false
        flow.author.enabled = false
        flow.runner.enabled = false
        flow.validator.enabled = false
        flow.device = deviceOn
        return flow
    }()

    public static let presets: [AgentFlow] = [.full, .authorOnly, .runExisting, .repositoryQuestions, .deviceControl]

    // MARK: Hand-over to the agent process

    public var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ text: String) -> AgentFlow? {
        guard let data = text.data(using: .utf8), let flow = try? JSONDecoder().decode(AgentFlow.self, from: data), flow.isUsable else { return nil }
        return flow.clamped
    }

    /// The same flow with every limit inside a sane range, so a hand-edited value cannot starve or run away an agent.
    public var clamped: AgentFlow {
        var flow = self
        for role in Role.allCases {
            flow[role].maxTurns = min(max(flow[role].maxTurns, 1), 20)
            flow[role].maxToolCalls = min(max(flow[role].maxToolCalls, 1), 60)
        }
        flow.orchestratorMaxTurns = min(max(flow.orchestratorMaxTurns, 2), 30)
        return flow
    }
}
