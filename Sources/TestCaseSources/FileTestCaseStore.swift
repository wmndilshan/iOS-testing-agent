import Foundation

public enum TestCaseStoreError: Error, LocalizedError, Equatable {
    case invalidKey
    case emptyTitle
    case stepCount
    case incompleteStep(Int)
    case exists(String)
    case protected(String)
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "key must be 2-41 characters: letters, digits, '-' or '_'."
        case .emptyTitle: "title is required."
        case .stepCount: "give 1 to 25 steps."
        case .incompleteStep(let number): "step \(number) needs a non-empty action and expected."
        case .exists(let key): "\(key) already exists; choose another key."
        case .protected(let key): "\(key) exists and was not written by an agent; choose another key."
        case .missing(let key): "No such case: \(key)."
        }
    }
}

/// Test cases kept as `<key>.json` files in one folder: the one place cases are validated, written, copied and deleted,
/// used by the agent's `write_test_case` tool and by the app's Tests section.
public struct FileTestCaseStore: Sendable {
    /// Who may be replaced by a save.
    public enum Replacing: Sendable { case nothing, agentCases, anything }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The key as stored (trimmed, upper case), or nil when it is not a usable key.
    public static func normalizedKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespaces).uppercased()
        return key.range(of: #"^[A-Z0-9][A-Z0-9_-]{1,40}$"#, options: .regularExpression) != nil ? key : nil
    }

    public func url(key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    public func keys() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix("_detail.json") }
            .map { String($0.dropLast(5)) }.sorted()
    }

    public func load(key: String) throws -> TestCase {
        guard let data = try? Data(contentsOf: url(key: key)) else { throw TestCaseStoreError.missing(key) }
        guard let value = try? JSONDecoder().decode(TestCase.self, from: data) else { throw TestCaseSourceError.unreadable("\(key).json") }
        return value
    }

    /// Checks a case and returns it cleaned: key normalized, steps renumbered by position.
    public static func validated(key: String, title: String, source: String, steps: [TestCaseStep]) throws -> TestCase {
        guard let key = normalizedKey(key) else { throw TestCaseStoreError.invalidKey }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw TestCaseStoreError.emptyTitle }
        guard (1...25).contains(steps.count) else { throw TestCaseStoreError.stepCount }
        var numbered: [TestCaseStep] = []
        for (offset, step) in steps.enumerated() {
            guard !step.action.trimmingCharacters(in: .whitespaces).isEmpty, !step.expected.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw TestCaseStoreError.incompleteStep(offset + 1)
            }
            numbered.append(TestCaseStep(number: offset + 1, action: step.action, data: step.data, expected: step.expected))
        }
        return TestCase(key: key, title: title, source: source, steps: numbered)
    }

    /// Writes the case (atomically, pretty-printed). `replacing` says which existing file may be overwritten.
    @discardableResult
    public func save(key: String, title: String, source: String, steps: [TestCaseStep], replacing: Replacing = .nothing) throws -> TestCase {
        let value = try Self.validated(key: key, title: title, source: source, steps: steps)
        let target = url(key: value.key)
        if let existing = try? Data(contentsOf: target) {
            switch replacing {
            case .nothing: throw TestCaseStoreError.exists(value.key)
            case .agentCases: if (try? JSONDecoder().decode(TestCase.self, from: existing))?.source != "agent" { throw TestCaseStoreError.protected(value.key) }
            case .anything: break
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: target, options: .atomic)
        return value
    }

    public func delete(key: String) throws {
        guard FileManager.default.fileExists(atPath: url(key: key).path) else { throw TestCaseStoreError.missing(key) }
        try FileManager.default.removeItem(at: url(key: key))
    }

    /// Copies a case to a new key; the copy is a person's case ("manual"), whatever the original's source was.
    @discardableResult
    public func duplicate(key: String, as newKey: String) throws -> TestCase {
        let original = try load(key: key)
        return try save(key: newKey, title: original.title, source: "manual", steps: original.steps)
    }
}
