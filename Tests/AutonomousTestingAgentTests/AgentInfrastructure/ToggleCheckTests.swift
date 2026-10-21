import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure

@Suite("Toggle check")
struct ToggleCheckTests {
    private func element(_ id: String = "e", role: String = "switch", identifier: String? = "Ask", value: String?, x: Double = 10, y: Double = 10) -> UIElementSnapshot {
        UIElementSnapshot(id: id, role: role, label: "Ask", identifier: identifier, value: value, isEnabled: true, isHittable: true,
                          frame: ElementFrame(x: x, y: y, width: 40, height: 20))
    }

    @Test("Only switches and checkboxes with an on or off value are toggles")
    func isToggle() {
        #expect(ToggleCheck.isToggle(element(value: "0")))
        #expect(ToggleCheck.isToggle(element(role: "checkBox", value: "checked")))
        #expect(!ToggleCheck.isToggle(element(role: "button", value: "0")))
        #expect(!ToggleCheck.isToggle(element(value: "Hello")))
        #expect(!ToggleCheck.isToggle(element(value: nil)))
    }

    @Test("An unchanged value is reported, a changed one is not")
    func unchanged() {
        let before = element(value: "0")
        #expect(ToggleCheck.unchanged(before: before, after: [element(value: "0")]) != nil)
        #expect(ToggleCheck.unchanged(before: before, after: [element(value: "1")]) == nil)
        #expect(ToggleCheck.unchanged(before: before, after: []) == nil)
    }
}
