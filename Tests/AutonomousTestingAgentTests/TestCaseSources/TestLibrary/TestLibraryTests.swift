import Testing
import Foundation
import TestCaseSources
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

private func tempDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-library-\(UUID().uuidString)")
}

private let steps = [TestCaseStep(number: 9, action: "Tap Login", data: "", expected: "Home is visible")]

@Suite("File test case store")
struct FileTestCaseStoreTests {
    @Test("A saved case is renumbered, normalized and read back")
    func roundTrip() throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTestCaseStore(directory: dir)
        let saved = try store.save(key: " login-1 ", title: "Login", source: "manual", steps: steps + steps)
        #expect(saved.key == "LOGIN-1" && saved.steps.map(\.number) == [1, 2])
        #expect(try store.load(key: "LOGIN-1") == saved)
        #expect(store.keys() == ["LOGIN-1"])
    }

    @Test("Bad input is refused with a reason", arguments: [("x", "t", 1), ("OK-1", " ", 1), ("OK-1", "t", 0), ("OK-1", "t", 26)])
    func refuses(key: String, title: String, count: Int) {
        let store = FileTestCaseStore(directory: tempDirectory())
        let many = Array(repeating: steps[0], count: count)
        #expect(throws: TestCaseStoreError.self) { try store.save(key: key, title: title, source: "manual", steps: many) }
    }

    @Test("A step without an expected result is refused")
    func incompleteStep() {
        let store = FileTestCaseStore(directory: tempDirectory())
        #expect(throws: TestCaseStoreError.incompleteStep(1)) { try store.save(key: "OK-1", title: "t", source: "manual", steps: [TestCaseStep(number: 1, action: "Tap", expected: "")]) }
    }

    @Test("Replacement rules: nothing by default, agent cases for the agent, anything for a person's edit")
    func replacement() throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTestCaseStore(directory: dir)
        try store.save(key: "A-1", title: "t", source: "manual", steps: steps)
        #expect(throws: TestCaseStoreError.exists("A-1")) { try store.save(key: "A-1", title: "t", source: "manual", steps: steps) }
        #expect(throws: TestCaseStoreError.protected("A-1")) { try store.save(key: "A-1", title: "t", source: "agent", steps: steps, replacing: .agentCases) }
        try store.save(key: "A-1", title: "edited", source: "manual", steps: steps, replacing: .anything)
        #expect(try store.load(key: "A-1").title == "edited")
    }

    @Test("Duplicate makes a manual copy; delete removes it")
    func duplicateAndDelete() throws {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTestCaseStore(directory: dir)
        try store.save(key: "A-1", title: "t", source: "agent", steps: steps)
        let copy = try store.duplicate(key: "A-1", as: "A-2")
        #expect(copy.source == "manual" && store.keys() == ["A-1", "A-2"])
        try store.delete(key: "A-1")
        #expect(store.keys() == ["A-2"])
        #expect(throws: TestCaseStoreError.missing("A-1")) { try store.delete(key: "A-1") }
    }
}

private struct FileBackedLibrary: TestCaseLibraryStoring {
    let store: FileTestCaseStore
    func all() -> [TestCaseRecord] {
        store.keys().compactMap { try? store.load(key: $0) }.map {
            TestCaseRecord(key: $0.key, title: $0.title, source: $0.source, steps: $0.steps.map { TestStepDraft(action: $0.action, data: $0.data, expected: $0.expected) }, isEditable: true)
        }
    }
    func save(_ record: TestCaseRecord, isNew: Bool) throws {
        try store.save(key: record.key, title: record.title, source: record.source,
                       steps: record.steps.map { TestCaseStep(number: 0, action: $0.action, data: $0.data, expected: $0.expected) }, replacing: isNew ? .nothing : .anything)
    }
    func delete(key: String) throws { try store.delete(key: key) }
    func duplicate(key: String, as newKey: String) throws { try store.duplicate(key: key, as: newKey) }
    func normalizedKey(_ raw: String) -> String? { FileTestCaseStore.normalizedKey(raw) }
    func fileURL(key: String) -> URL? { store.url(key: key) }
}

@MainActor
@Suite("Test library state")
struct TestLibraryStateTests {
    private func makeState() -> (TestLibraryState, URL) {
        let dir = tempDirectory()
        return (TestLibraryState(store: FileBackedLibrary(store: FileTestCaseStore(directory: dir))), dir)
    }

    @Test("Create, edit, duplicate and delete through the state")
    func lifecycle() {
        let (state, dir) = makeState(); defer { try? FileManager.default.removeItem(at: dir) }
        state.startNew()
        state.draft?.key = "new-1"; state.draft?.title = "New"
        state.draft?.steps[0].action = "Tap"; state.draft?.steps[0].expected = "Seen"
        #expect(state.saveDraft())
        #expect(state.selectedKey == "NEW-1" && state.records.count == 1)

        state.startEditing()
        state.draft?.title = "Renamed"
        #expect(state.saveDraft() && state.selected?.title == "Renamed")

        state.duplicateSelected()
        #expect(state.selectedKey == "NEW-1-COPY")
        state.duplicateSelected()
        #expect(state.selectedKey == "NEW-1-COPY-COPY")

        state.delete(key: "NEW-1-COPY-COPY")
        #expect(state.records.count == 2 && state.selected == nil)
    }

    @Test("A bad draft stays open with a message")
    func invalidDraftStaysOpen() {
        let (state, dir) = makeState(); defer { try? FileManager.default.removeItem(at: dir) }
        state.startNew()
        #expect(!state.saveDraft())
        #expect(state.isEditing && state.errorMessage != nil)
    }

    @Test("Steps can be added, moved and removed, but never down to zero")
    func stepEditing() {
        let (state, dir) = makeState(); defer { try? FileManager.default.removeItem(at: dir) }
        state.startNew()
        state.addStep()
        state.draft?.steps[0].action = "first"; state.draft?.steps[1].action = "second"
        let first = state.draft!.steps[0].id
        state.moveStep(first, by: 1)
        #expect(state.draft?.steps.map(\.action) == ["second", "first"])
        state.removeStep(first)
        state.removeStep(state.draft!.steps[0].id)
        #expect(state.draft?.steps.count == 1)
    }
}
