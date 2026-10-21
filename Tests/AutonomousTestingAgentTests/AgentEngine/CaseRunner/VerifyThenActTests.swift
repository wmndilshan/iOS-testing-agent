import Testing
import Foundation
@testable import AgentEngine

@Suite("Check-then-act steps")
struct VerifyThenActTests {
    private let real = "Verify the three filter options are present, then tap the option with accessibility id 'saved-display-filter-option-Mine' (visible label 'Mine'). Expected: Options 'All', 'Mine' and 'Not Mine' were all visible, the selection is applied, and the Display Filter sheet closes."

    @Test("The check before 'then' is separated from the action, which names the tap")
    func splits() throws {
        let text = StepText(real)
        let split = try #require(text.verifyThenAct)
        #expect(split.check == "Verify the three filter options are present")
        #expect(split.act.hasPrefix("tap the option with accessibility id"))
        #expect(text.action == split.act && !text.verifiesOnly)
        #expect(text.expected.contains("the selection is applied"))
    }

    @Test("After the action, the judge is told earlier visibility cannot be required")
    func judgeNote() {
        let text = StepText(real)
        #expect(text.expectedAfterAction.hasPrefix(text.expected))
        #expect(text.expectedAfterAction.contains("BEFORE the action"))
        #expect(StepText("Tap Login. Expected: Home is visible").expectedAfterAction == "Home is visible")
    }

    @Test("Ordinary steps are not split: actions first, check-only steps, and a check whose second part is not an action")
    func notSplit() {
        #expect(StepText("Tap the field, then type men watches. Expected: results").verifyThenAct == nil)
        #expect(StepText("Verify the home screen is shown. Expected: Home").verifyThenAct == nil)
        #expect(StepText("Verify the list is sorted, then check the footer text. Expected: ok").verifyThenAct == nil)
        let scroll = StepText("Check grid view by scrolling horizontally. Expected: items")
        #expect(scroll.verifyThenAct == nil && !scroll.verifiesOnly)
        #expect(StepText("Validate the title. Expected: Title").verifiesOnly)
    }
}
