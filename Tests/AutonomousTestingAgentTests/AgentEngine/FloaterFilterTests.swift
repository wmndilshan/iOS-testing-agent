import Testing
import Foundation
@testable import AgentCore
@testable import AgentEngine

@Suite("Floating overlay buttons")
struct FloaterFilterTests {
    private func observation() -> Observation {
        Observation(snapshotID: "s", timestamp: Date(), bundleID: "com.apple.mobilesafari", appState: .runningForeground, source: .accessibilityTree, elements: [
            UIElementSnapshot(id: "a", role: "button", label: "Cancel", identifier: "cancel"),
            UIElementSnapshot(id: "b", role: "button", label: "Conversation", identifier: "floating-chat-button")
        ])
    }

    @Test("The chat bubble is hidden from a step that never mentions it")
    func hidden() {
        let kept = PlannerNotes.withoutUnrelatedFloaters(observation(), for: "Re-open the Add New Collection Create screen via the action drawer").elements.map(\.id)
        #expect(kept == ["a"])
    }

    @Test("A step about the chat keeps it")
    func kept() {
        #expect(PlannerNotes.withoutUnrelatedFloaters(observation(), for: "Tap the Zeus chat bubble").elements.count == 2)
        #expect(PlannerNotes.withoutUnrelatedFloaters(observation(), for: "Open the conversation").elements.count == 2)
    }
}
