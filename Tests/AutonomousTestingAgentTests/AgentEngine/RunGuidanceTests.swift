import Testing
import Foundation
@testable import AgentCore
@testable import AgentEngine

@Suite("Run guidance")
struct RunGuidanceTests {
    @Test("Plain words become substitutions, and anything else stays a note")
    func parsing() {
        #expect(GuidanceParser.parse("use Test2 instead of Test1").substitutions == [.init(from: "Test1", to: "Test2")])
        #expect(GuidanceParser.parse("Use \"Test2\" instead of 'Test1'.").substitutions == [.init(from: "Test1", to: "Test2")])
        #expect(GuidanceParser.parse("replace Test1 with Test2").substitutions == [.init(from: "Test1", to: "Test2")])
        #expect(GuidanceParser.parse("Test1 → Test2").substitutions == [.init(from: "Test1", to: "Test2")])
        #expect(GuidanceParser.parse("Test1 -> Test2").substitutions == [.init(from: "Test1", to: "Test2")])
        #expect(GuidanceParser.parse("Test1=Test2").substitutions == [.init(from: "Test1", to: "Test2")])
        #expect(GuidanceParser.parse("instead of Test1, use Test2").substitutions == [.init(from: "Test1", to: "Test2")])
        let mixed = GuidanceParser.parse("use Test2 instead of Test1; keep the Table view")
        #expect(mixed.substitutions.count == 1 && mixed.notes == ["keep the Table view"])
        #expect(GuidanceParser.parse("use Test1 instead of Test1").isEmpty)
        #expect(GuidanceParser.parse("   ").isEmpty)
    }

    @Test("Substitutions change whole words only, and chains collapse so applying once is right")
    func applying() {
        var guidance = GuidanceParser.parse("use Test2 instead of Test1")
        #expect(guidance.apply(to: "Type Test1 in the name. Test Data: Test1. Expected: Test1 is shown; Test10 is not") == "Type Test2 in the name. Test Data: Test2. Expected: Test2 is shown; Test10 is not")
        guidance.merge(GuidanceParser.parse("use Test3 instead of Test2"))
        #expect(guidance.substitutions == [.init(from: "Test1", to: "Test3"), .init(from: "Test2", to: "Test3")])
        #expect(guidance.apply(to: "Test1 and Test2") == "Test3 and Test3")
        #expect(guidance.summary == "Test1 → Test3; Test2 → Test3")
    }

    @Test("The prompt block names the new values and the notes, and is empty with nothing to say")
    func block() {
        #expect(RunGuidance().promptBlock.isEmpty)
        let block = GuidanceParser.parse("use Test2 instead of Test1; keep the Table view").promptBlock
        #expect(block.contains("use Test2 instead of Test1") && block.contains("keep the Table view") && block.contains("never overrides"))
    }

    @Test("A case takes the guidance from the step it is given, and earlier steps are left as they were")
    func caseDefinition() {
        let definition = CaseDefinition(key: "K-1", title: "T", steps: (1...3).map { CaseStep(number: $0, text: "Step \($0) Test Data: Test1") })
        let guided = definition.applying(GuidanceParser.parse("Test1 → Test2"), fromStep: 2)
        #expect(guided.steps.map(\.text) == ["Step 1 Test Data: Test1", "Step 2 Test Data: Test2", "Step 3 Test Data: Test2"])
        #expect(definition.applying(RunGuidance()).steps.map(\.text) == definition.steps.map(\.text))
    }

    @Test("Guidance is kept per case until it is cleared")
    func store() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guidance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GuidanceStore(directory: folder)
        #expect(store.load("DEMO-TC-873").isEmpty)
        store.save(GuidanceParser.parse("use Test2 instead of Test1; keep the Table view"), for: "DEMO-TC-873")
        #expect(store.load("DEMO-TC-873").substitutions == [.init(from: "Test1", to: "Test2")] && store.load("DEMO-TC-873").notes == ["keep the Table view"])
        #expect(store.load("DEMO-TC-874").isEmpty)
        store.clear("DEMO-TC-873")
        #expect(store.load("DEMO-TC-873").isEmpty)
        store.save(GuidanceParser.parse("a → b"), for: "../escape")
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("escape.json").path))
        #expect(store.load("../escape").substitutions.count == 1)
    }

    @Test("A line typed to the running case is a note, never an answer")
    func notes() {
        #expect(StdinAnswers.note(in: "@@NOTE use Test2 instead of Test1") == "use Test2 instead of Test1")
        #expect(StdinAnswers.note(in: "note: keep the Table view") == "keep the Table view")
        #expect(StdinAnswers.note(in: "done") == nil)
        #expect(StdinAnswers.note(in: "s3cret note: x") == nil)
        #expect(StdinAnswers.note(in: "@@NOTE   ") == nil)
    }
}

@Suite("Name clashes")
struct NameClashTests {
    private func screen(_ labels: [String], field: String? = nil) -> Observation {
        var elements = labels.enumerated().map { UIElementSnapshot(id: "e\($0.offset)", role: "staticText", label: $0.element) }
        if let field { elements.append(UIElementSnapshot(id: "f", role: "textField", label: "Collection Name", value: field)) }
        return Observation(snapshotID: "s", timestamp: Date(), bundleID: "com.apple.mobilesafari", appState: .runningForeground, source: .accessibilityTree, elements: elements)
    }

    @Test("The app saying a name is taken is found, with the value from the step's test data")
    func detect() {
        let conflict = ConflictDetector.detect(screen(["Create Collection", "Name already exists. Try a different name."]), stepText: "Type the name. Test Data: Test1. Expected: it is shown")
        #expect(conflict == DataConflict(value: "Test1", message: "Name already exists. Try a different name."))
        // No test data in the step: the filled text field says what was typed.
        #expect(ConflictDetector.detect(screen(["Name already exists."], field: "Test7"), stepText: "Tap Add Symbols")?.value == "Test7")
        #expect(ConflictDetector.detect(screen(["Create Collection", "Collection Symbols"]), stepText: "Test Data: Test1") == nil)
        #expect(ConflictDetector.detect(screen(["Name already exists."]), stepText: "Tap Add Symbols") == nil)
        #expect(ConflictDetector.detect(nil, stepText: "Test Data: Test1") == nil)
    }

    @Test("The next free names are suggested, skipping those on screen")
    func suggest() {
        #expect(NameSuggester.suggest(for: "Test1") == ["Test2", "Test3", "Test4"])
        #expect(NameSuggester.suggest(for: "Test1", avoiding: ["test2", "Test3"], count: 2) == ["Test4", "Test5"])
        #expect(NameSuggester.suggest(for: "Alpha", count: 2) == ["Alpha2", "Alpha3"])
        #expect(NameSuggester.suggest(for: "Test9", count: 1) == ["Test10"])
    }
}
