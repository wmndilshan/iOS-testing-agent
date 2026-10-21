import Testing
import Foundation
@testable import AgentCore
@testable import AgentEngine

@Suite("Conditional steps")
struct ConditionalStepTests {
    @Test("A step that only handles something if it is there is conditional")
    func conditional() {
        for text in ["Handle the system permission dialog if it appears.", "Dismiss any post-login drawers", "Accept the cookie banner if present",
                     "Tap Allow if prompted", "Close the tutorial (optional)"] {
            #expect(StepText.isConditional(text), Comment(rawValue: text))
        }
    }

    @Test("An ordinary step is not conditional, even when it mentions a dialog or an if")
    func ordinary() {
        for text in ["Tap the Login button", "Verify the dialog is shown", "Enter the username in the username field", "Open the filter menu and tap Mine"] {
            #expect(!StepText.isConditional(text), Comment(rawValue: text))
        }
    }
}

@Suite("What the judge is told about the screen")
@MainActor
struct JudgeTreeNoteTests {
    @Test("Disabled controls are named, with their identifiers, so a greyed-out button is not judged enabled")
    func disabled() {
        let observation = Observation(snapshotID: "s", bundleID: "b", appState: .runningForeground, elements: [
            UIElementSnapshot(id: "a", role: "button", label: "Symbol", identifier: "display-mode-symbol"),
            UIElementSnapshot(id: "b", role: "button", label: "Logo", identifier: "display-mode-logo", isEnabled: false),
            UIElementSnapshot(id: "c", role: "button", label: "Class", isEnabled: false),
            UIElementSnapshot(id: "d", role: "secureTextField", label: "Password", isEnabled: false),
        ])
        let note = CaseRunSession.treeNote(for: observation)
        #expect(note.contains("DISABLED") && note.contains("Logo (display-mode-logo) | Class"))
        #expect(!note.contains("Password (") && note.contains("Accessibility labels on screen"))
    }

    @Test("With nothing disabled the note says nothing about it")
    func none() {
        let observation = Observation(snapshotID: "s", bundleID: "b", appState: .runningForeground, elements: [UIElementSnapshot(id: "a", role: "button", label: "Save")])
        #expect(!CaseRunSession.treeNote(for: observation).contains("DISABLED"))
    }
}
