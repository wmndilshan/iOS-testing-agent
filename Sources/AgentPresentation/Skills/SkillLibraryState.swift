import Foundation
import AgentCore

/// The learned step skills (`.skills/steps/*.json`) with the two things a person may do to one: let it be used again
/// after it was quarantined, or forget it. It never creates or edits a skill's actions.
@MainActor
public final class SkillLibraryState: ObservableObject {
    public struct Row: Identifiable, Sendable, Equatable {
        public let id: String
        public let testKey: String
        public let stepNumber: Int
        public let stepText: String
        public let bundleID: String
        public let actions: [String]
        public let successes: Int
        public let failures: Int
        public let quarantined: Bool
        public let learnedAt: Date
        public let lastUsedAt: Date?

        init(_ skill: StepSkill) {
            id = skill.id
            testKey = skill.testKey
            stepNumber = skill.stepNumber
            stepText = skill.stepText
            bundleID = skill.bundleID
            actions = skill.actions.map { $0.intent.isEmpty ? $0.action.rawValue : $0.intent }
            successes = skill.successes
            failures = skill.failures
            quarantined = skill.quarantined
            learnedAt = skill.learnedAt
            lastUsedAt = skill.lastUsedAt
        }
    }

    @Published public private(set) var rows: [Row] = []
    @Published public var selectedID: String?

    private let store: any StepSkillLibraryStoring

    public init(store: any StepSkillLibraryStoring) {
        self.store = store
    }

    public var selected: Row? { rows.first { $0.id == selectedID } }
    public var quarantinedCount: Int { rows.filter(\.quarantined).count }

    public func reload() async {
        rows = await store.all().map(Row.init)
        if let selectedID, !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    /// Lets a quarantined skill be replayed again; its failure streak starts over.
    public func unquarantine(_ id: String) async {
        await store.setQuarantined(id: id, false)
        await reload()
    }

    public func forget(_ id: String) async {
        await store.delete(id: id)
        await reload()
    }
}
