import Foundation
import AgentCore

/// Learned step skills, one JSON file each. Nothing secret is ever written: a skill whose content looks like a secret is refused.
public actor StepSkillStore: StepSkillLibraryStoring {
    private let directory: URL
    /// Where skills were kept before the folder was renamed. Read when a skill is not in `directory`; never written.
    private let legacyDirectory: URL?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(directory: URL, legacyDirectory: URL? = nil) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    private func url(for id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    public func load(id: String) -> StepSkill? {
        let file = "\(id).json"
        for folder in [directory] + (legacyDirectory.map { [$0] } ?? []) {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(file)) { return try? decoder.decode(StepSkill.self, from: data) }
        }
        return nil
    }

    /// Every learned skill; a skill saved again under the new folder replaces its old-folder copy.
    public func all() -> [StepSkill] {
        var byID: [String: StepSkill] = [:]
        for folder in (legacyDirectory.map { [$0] } ?? []) + [directory] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                if let skill = (try? Data(contentsOf: file)).flatMap({ try? decoder.decode(StepSkill.self, from: $0) }) { byID[skill.id] = skill }
            }
        }
        return byID.values.sorted { ($0.testKey, $0.stepNumber) < ($1.testKey, $1.stepNumber) }
    }

    /// The skill to replay for this step on this screen, or nil: none learned, quarantined, another app, or a start screen that
    /// does not look like the one it was learned on.
    public func applicable(testKey: String, stepText: String, bundleID: String, observation: Observation) -> StepSkill? {
        guard let skill = load(id: StepSkill.makeID(testKey: testKey, stepText: stepText)), !skill.quarantined, skill.bundleID == bundleID else { return nil }
        guard ScreenSignature(from: observation).similarity(to: skill.preScreen) >= StepSkill.minimumStartSimilarity else { return nil }
        return skill
    }

    /// Saves a skill, keeping the counters of an earlier version of the same skill. Returns false when it was refused.
    @discardableResult
    public func save(_ skill: StepSkill) -> Bool {
        var skill = skill
        if let previous = load(id: skill.id) {
            skill.successes = previous.successes + 1
            skill.failures = previous.failures
        }
        guard let data = try? encoder.encode(skill), !SecretRedactor.containsSecret(String(decoding: data, as: UTF8.self)) else { return false }
        return (try? AtomicFile.write(data, to: url(for: skill.id))) != nil
    }

    public func recordSuccess(id: String) {
        guard var skill = load(id: id) else { return }
        skill.successes += 1
        skill.consecutiveFailures = 0
        skill.lastUsedAt = Date()
        write(skill)
    }

    /// A failed replay counts against the skill; after `quarantineThreshold` in a row it is no longer used.
    public func recordFailure(id: String) {
        guard var skill = load(id: id) else { return }
        skill.failures += 1
        skill.consecutiveFailures += 1
        skill.lastUsedAt = Date()
        if skill.consecutiveFailures >= StepSkill.quarantineThreshold { skill.quarantined = true }
        write(skill)
    }

    /// Puts a skill in or out of quarantine. Leaving quarantine also clears the failure streak, or the next failure would quarantine it again.
    public func setQuarantined(id: String, _ quarantined: Bool) {
        guard var skill = load(id: id) else { return }
        skill.quarantined = quarantined
        if !quarantined { skill.consecutiveFailures = 0 }
        write(skill)
    }

    /// Removes a learned skill; the step is planned from scratch the next time.
    public func delete(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
        if let legacyDirectory { try? FileManager.default.removeItem(at: legacyDirectory.appendingPathComponent("\(id).json")) }
    }

    private func write(_ skill: StepSkill) {
        guard let data = try? encoder.encode(skill) else { return }
        try? AtomicFile.write(data, to: url(for: skill.id))
    }
}
