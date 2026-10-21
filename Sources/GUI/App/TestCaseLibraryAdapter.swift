import Foundation
import AgentCore
import AgentPresentation
import AgentComposition
import TestCaseSources

/// Connects the Tests section to the case files: `TestCases/` is editable, `Scripts/AIO/generated/` (fetched cases) is read-only.
struct TestCaseLibraryAdapter: TestCaseLibraryStoring {
    private let store: FileTestCaseStore
    private let fetched: URL

    init(projectRoot: URL) {
        store = FileTestCaseStore(directory: projectRoot.appendingPathComponent("TestCases"))
        fetched = projectRoot.appendingPathComponent("Scripts/AIO/generated")
    }

    func all() -> [TestCaseRecord] {
        var byKey: [String: TestCaseRecord] = [:]
        let fetchedSource = FileTestCaseSource(directory: fetched)
        let fetchedKeys = ((try? FileManager.default.contentsOfDirectory(atPath: fetched.path)) ?? [])
            .filter { ($0.hasSuffix(".json") && !$0.hasSuffix("_detail.json")) || $0.hasSuffix(".md") }
            .map { ($0 as NSString).deletingPathExtension }
        for key in Set(fetchedKeys) {
            if let value = Self.blocking({ try await fetchedSource.testCase(key: key) }) { byKey[key] = Self.record(value, editable: false) }
        }
        for key in store.keys() {
            if let value = try? store.load(key: key) { byKey[key] = Self.record(value, editable: true) }
        }
        return byKey.values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    func save(_ record: TestCaseRecord, isNew: Bool) throws {
        try store.save(key: record.key, title: record.title, source: record.source, steps: Self.steps(record), replacing: isNew ? .nothing : .anything)
    }

    func delete(key: String) throws { try store.delete(key: key) }
    func duplicate(key: String, as newKey: String) throws { try store.duplicate(key: key, as: newKey) }
    func normalizedKey(_ raw: String) -> String? { FileTestCaseStore.normalizedKey(raw) }

    func fileURL(key: String) -> URL? {
        let url = store.url(key: key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func record(_ value: TestCase, editable: Bool) -> TestCaseRecord {
        TestCaseRecord(key: value.key, title: value.title, source: value.source,
                       steps: value.steps.map { TestStepDraft(action: $0.action, data: $0.data, expected: $0.expected) }, isEditable: editable)
    }

    private static func steps(_ record: TestCaseRecord) -> [TestCaseStep] {
        record.steps.enumerated().map { TestCaseStep(number: $0.offset + 1, action: $0.element.action, data: $0.element.data, expected: $0.element.expected) }
    }

    /// `TestCaseSource` is async; the library lists small local files, so wait for it here.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = try? await work(); done.signal() }
        done.wait()
        return box.value
    }

    private final class ResultBox<T: Sendable>: @unchecked Sendable { var value: T? }
}
