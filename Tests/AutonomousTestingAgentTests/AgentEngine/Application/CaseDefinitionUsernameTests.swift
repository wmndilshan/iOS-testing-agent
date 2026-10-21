import Testing
import Foundation
import AgentCore
@testable import AgentEngine

@Suite("Case username substitution")
struct CaseDefinitionUsernameTests {
    private func definition(_ text: String) -> CaseDefinition {
        CaseDefinition(key: "K", title: "T", steps: [CaseStep(number: 4, text: text)])
    }

    @Test func testADottedUsernameIsReplacedWholeNotUpToItsFirstDot() {
        let step = definition("Enter the valid username in the username field. Test Data: r.ruwan. Expected: Username should be entered successfully")
            .withUsername("tester", onlyStep: 4).steps[0]
        #expect(step.text == "Enter the valid username in the username field. Test Data: tester. Expected: Username should be entered successfully")
    }

    @Test func testAStepWithoutTestDataIsLeftAlone() {
        let text = "Enter the username. Expected: done"
        #expect(definition(text).withUsername("x", onlyStep: 4).steps[0].text == text)
    }
}
