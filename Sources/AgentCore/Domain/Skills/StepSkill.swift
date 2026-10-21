import Foundation

/// The identifiers on a screen: enough to recognise a screen without comparing prices, text or other values that change.
public struct ScreenSignature: Codable, Sendable, Equatable {
    /// `role|identifier` of every non-secure element that has an identifier, sorted so stored files are stable.
    public let identifiers: [String]

    /// A start screen must look at least this much like the learned one before a skill is replayed.
    public static let minimumMatch = 0.85
    /// How much a replay's end screen must look like the learned end screen (pages vary between visits more than app chrome).
    public static let minimumEndMatch = 0.6

    public init(identifiers: [String]) {
        self.identifiers = Array(Set(identifiers)).sorted()
    }

    /// Roles whose short, number-free labels name what a screen offers ("Search", "Share", "Add to Cart") and stay the same
    /// between visits, unlike prices, counts and promotions.
    private static let namedControlRoles: Set<String> = ["button", "textField", "searchField", "switch", "tab", "link", "cell"]

    public init(from observation: Observation) {
        var entries: [String] = []
        for element in observation.elements where !element.isSecure {
            if let identifier = element.identifier, !identifier.isEmpty {
                entries.append("\(element.role)|\(Self.stable(identifier))")
            } else if Self.namedControlRoles.contains(element.role), let label = element.label, Self.isStableLabel(label) {
                entries.append("\(element.role)|label:\(label)")
            }
        }
        self.init(identifiers: entries)
    }

    /// An identifier without the parts that change between launches: query strings (`Window?View=Narrow&UUID=...`) and UUIDs.
    static func stable(_ identifier: String) -> String {
        let base = identifier.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? identifier
        return base.replacingOccurrences(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, with: "", options: .regularExpression)
    }

    private static func isStableLabel(_ label: String) -> Bool {
        label.count >= 2 && label.count <= 32 && !label.contains("\n") && label.rangeOfCharacter(from: .decimalDigits) == nil
    }

    /// Controls that appear only while something loads or is typed; they say nothing about which screen this is.
    private static let transient: Set<String> = ["button|ReloadButton", "button|StopButton"]

    /// Share of identifiers the two screens have in common (1 for the same screen, 0 for unrelated screens).
    public func similarity(to other: ScreenSignature) -> Double {
        let a = Set(identifiers).subtracting(Self.transient), b = Set(other.identifiers).subtracting(Self.transient)
        let union = a.union(b).count
        return union == 0 ? 1 : Double(a.intersection(b).count) / Double(union)
    }

    /// True when every identifier of `other` is on this screen: nothing the other screen showed is missing.
    public func contains(allOf other: ScreenSignature) -> Bool {
        Set(other.identifiers).subtracting(Self.transient).isSubset(of: Set(identifiers))
    }
}

/// One action of a learned step: a TestIR action with its target and non-secret arguments.
public struct StepSkillAction: Codable, Sendable, Equatable {
    public let action: IRAction
    public let target: IRTarget?
    public let arguments: [String: AnyCodableValue]
    public let intent: String

    public init(action: IRAction, target: IRTarget?, arguments: [String: AnyCodableValue], intent: String) {
        self.action = action
        self.target = target
        self.arguments = arguments
        self.intent = intent
    }
}

/// What the agent did for one test step and what the screen looked like before and after, kept so the next run can
/// repeat it without planning or judging. A skill is learned only from a step whose result was judged correct.
public struct StepSkill: Codable, Sendable, Equatable {
    public let id: String
    public let testKey: String
    public let stepNumber: Int
    public let stepText: String
    public let bundleID: String
    /// Empty for a step that only checks the screen.
    public let actions: [StepSkillAction]
    public let preScreen: ScreenSignature
    public let postScreen: ScreenSignature
    /// How the actions were approved when they were learned.
    public let approvalSource: String
    public let learnedAt: Date
    public var successes: Int
    public var failures: Int
    public var consecutiveFailures: Int
    public var lastUsedAt: Date?
    public var quarantined: Bool

    /// A screen must look at least this much like the learned start screen before the skill is replayed.
    public static let minimumStartSimilarity = 0.85
    /// Consecutive replay failures after which a skill stops being used.
    public static let quarantineThreshold = 3

    public init(testKey: String, stepNumber: Int, stepText: String, bundleID: String, actions: [StepSkillAction], preScreen: ScreenSignature,
                postScreen: ScreenSignature, approvalSource: String, learnedAt: Date = Date()) {
        self.id = Self.makeID(testKey: testKey, stepText: stepText)
        self.testKey = testKey
        self.stepNumber = stepNumber
        self.stepText = stepText
        self.bundleID = bundleID
        self.actions = actions
        self.preScreen = preScreen
        self.postScreen = postScreen
        self.approvalSource = approvalSource
        self.learnedAt = learnedAt
        self.successes = 1
        self.failures = 0
        self.consecutiveFailures = 0
        self.lastUsedAt = nil
        self.quarantined = false
    }

    /// Stable per test case and step wording, so editing the step text in the test case starts a fresh skill.
    public static func makeID(testKey: String, stepText: String) -> String {
        let normalized = stepText.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "aio.\(testKey).\(IntegrityHash.sha256Hex(normalized).prefix(12))"
    }
}

/// What the Skills screen may do with learned step skills: list them, let a quarantined one be used again, or forget one.
public protocol StepSkillLibraryStoring: Sendable {
    func all() async -> [StepSkill]
    func setQuarantined(id: String, _ quarantined: Bool) async
    func delete(id: String) async
}
