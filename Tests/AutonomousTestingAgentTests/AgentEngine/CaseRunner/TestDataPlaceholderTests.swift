import Testing
import Foundation
@testable import AgentEngine

@Suite("Test data placeholders")
struct TestDataPlaceholderTests {
    private let definition = CaseDefinition(key: "K-1", title: "t", steps: [
        CaseStep(number: 1, text: "Enter the password [CREDENTIALS]. Expected: logged in"),
        CaseStep(number: 2, text: "Scroll to the row for [HELD_SYMBOL]. Expected: row visible"),
        CaseStep(number: 3, text: "Inspect [HELD_SYMBOL] and [OTHER_ITEM2] below it. Expected: [HELD_SYMBOL] shows Qty"),
        CaseStep(number: 4, text: "Tap [x] and [AB]. Expected: ok"),
    ])

    @Test("Placeholders are found once, in order, without the credentials marker or short or lower-case brackets")
    func found() {
        #expect(definition.placeholders == ["HELD_SYMBOL", "OTHER_ITEM2"])
    }

    @Test("A given value replaces every use; names without a value stay as written")
    func replaced() {
        let filled = definition.withValues(["HELD_SYMBOL": "ALPHA", "OTHER_ITEM2": ""])
        #expect(filled.steps[1].text == "Scroll to the row for ALPHA. Expected: row visible")
        #expect(filled.steps[2].text == "Inspect ALPHA and [OTHER_ITEM2] below it. Expected: ALPHA shows Qty")
        #expect(filled.steps[0].text.contains("[CREDENTIALS]"))
        #expect(filled.placeholders == ["OTHER_ITEM2"])
    }

    @Test("A corrective note forbids changing state the step does not name")
    func guardRule() {
        let note = PlannerNotes.actionNote(stepText: "Scroll to the row", done: [], judgeFeedback: "row not visible")
        #expect(note.contains("Never change a filter, tab, sort order, setting or selection that this step does not name"))
        #expect(PlannerNotes.actionNote(stepText: "Scroll to the row", done: [], judgeFeedback: nil).contains("Never change a filter") == false)
    }
}
