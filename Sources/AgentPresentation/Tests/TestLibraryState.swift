import Foundation
import AgentCore

/// One step of a case as the Tests section shows and edits it.
public struct TestStepDraft: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var action: String
    public var data: String
    public var expected: String

    public init(action: String = "", data: String = "", expected: String = "") {
        self.action = action
        self.data = data
        self.expected = expected
    }
}

/// A case as the Tests section shows it. `isEditable` is false for cases fetched from AIO, which are refreshed from their source.
public struct TestCaseRecord: Identifiable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var source: String
    public var steps: [TestStepDraft]
    public var isEditable: Bool
    public var id: String { key }

    public init(key: String, title: String, source: String, steps: [TestStepDraft], isEditable: Bool) {
        self.key = key
        self.title = title
        self.source = source
        self.steps = steps
        self.isEditable = isEditable
    }
}

/// Where the Tests section keeps its cases. The app supplies it; AgentCore never reads `TestCaseSources` itself.
public protocol TestCaseLibraryStoring: Sendable {
    func all() -> [TestCaseRecord]
    /// Writes a new case (`isNew`) or replaces an existing editable one. Throws a message fit to show a person.
    func save(_ record: TestCaseRecord, isNew: Bool) throws
    func delete(key: String) throws
    func duplicate(key: String, as newKey: String) throws
    func normalizedKey(_ raw: String) -> String?
    func fileURL(key: String) -> URL?
}

/// The test cases a person can browse and manage: create, edit, copy, delete. Running one is the Run section's job.
@MainActor
public final class TestLibraryState: ObservableObject {
    @Published public private(set) var records: [TestCaseRecord] = []
    @Published public var selectedKey: String?
    @Published public var draft: TestCaseRecord?
    @Published public private(set) var draftIsNew = false
    @Published public var errorMessage: String?

    private let store: any TestCaseLibraryStoring

    public init(store: any TestCaseLibraryStoring) { self.store = store }

    public var selected: TestCaseRecord? { records.first { $0.key == selectedKey } }
    public var isEditing: Bool { draft != nil }

    public func reload() {
        records = store.all()
        if let selectedKey, !records.contains(where: { $0.key == selectedKey }) { self.selectedKey = nil }
    }

    public func fileURL(for key: String) -> URL? { store.fileURL(key: key) }

    // MARK: Editing

    public func startNew() {
        draft = TestCaseRecord(key: "", title: "", source: "manual", steps: [TestStepDraft()], isEditable: true)
        draftIsNew = true
        errorMessage = nil
    }

    public func startEditing() {
        guard let selected, selected.isEditable else { return }
        draft = selected
        draftIsNew = false
        errorMessage = nil
    }

    public func cancelEditing() {
        draft = nil
        errorMessage = nil
    }

    public func addStep() { draft?.steps.append(TestStepDraft()) }

    public func removeStep(_ id: UUID) {
        guard var current = draft, current.steps.count > 1 else { return }
        current.steps.removeAll { $0.id == id }
        draft = current
    }

    public func moveStep(_ id: UUID, by offset: Int) {
        guard var current = draft, let from = current.steps.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard current.steps.indices.contains(to) else { return }
        current.steps.swapAt(from, to)
        draft = current
    }

    /// Saves the draft. On a problem the draft stays open and `errorMessage` says what to fix.
    @discardableResult
    public func saveDraft() -> Bool {
        guard var current = draft else { return false }
        if let key = store.normalizedKey(current.key) { current.key = key }
        do {
            try store.save(current, isNew: draftIsNew)
            draft = nil
            errorMessage = nil
            reload()
            selectedKey = current.key
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Saves a case made elsewhere (a recorded Operate session) as a new case under a free key. Returns the saved key, or nil with `errorMessage` set.
    public func create(_ record: TestCaseRecord) -> String? {
        var made = record
        let base = store.normalizedKey(record.key) ?? "OPERATE"
        let taken = Set(store.all().map(\.key))
        var key = base, n = 2
        while taken.contains(key) { key = "\(base)-\(n)"; n += 1 }
        made.key = key
        do {
            try store.save(made, isNew: true)
            errorMessage = nil
            reload()
            selectedKey = key
            return key
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Copy and delete

    /// Copies a case under a free key (`KEY-COPY`, `KEY-COPY-2`, …) and selects the copy.
    public func duplicateSelected() {
        guard let source = selected else { return }
        let taken = Set(records.map(\.key))
        var candidate = "\(source.key)-COPY"
        var n = 2
        while taken.contains(candidate) { candidate = "\(source.key)-COPY-\(n)"; n += 1 }
        do {
            try store.duplicate(key: source.key, as: candidate)
            reload()
            selectedKey = candidate
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(key: String) {
        do {
            try store.delete(key: key)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
