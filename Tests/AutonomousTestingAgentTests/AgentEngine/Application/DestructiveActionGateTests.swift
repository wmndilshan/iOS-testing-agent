import Testing
import Foundation
import AgentCore
@testable import AgentEngine

/// The destructive-action gate: which steps need a person, and what the person is shown to identify the item.
@Suite("Destructive action gate")
struct DestructiveActionGateTests {
    private func step(_ intent: String, action: IRAction = .tap, label: String? = nil, identifier: String? = nil) -> IRStep {
        IRStep(id: "s", sourceStepNumber: 1, intent: intent, action: action, target: IRTarget(role: "button", identifier: identifier, label: label))
    }

    // MARK: Word list

    @Test(arguments: ["delete", "remove", "trash", "erase", "clear all", "log out", "logout", "sign out", "unsubscribe", "discard"])
    func testEveryListedWordIsDestructive(word: String) {
        #expect(DestructiveActionGate.isDestructive(step("Tap the \(word) button")))
    }

    @Test func testTheWordListIsExactlyTheDocumentedOne() {
        #expect(Set(DestructiveActionGate.words) == ["delete", "remove", "trash", "erase", "clear all", "log out", "logout", "sign out", "unsubscribe", "discard"])
    }

    @Test func testMatchingIgnoresCase() {
        #expect(DestructiveActionGate.isDestructive(step("DELETE the item")))
        #expect(DestructiveActionGate.isDestructive(step("Tap", label: "Sign Out")))
    }

    @Test func testTheTargetLabelAndIdentifierCountNotJustTheIntent() {
        #expect(DestructiveActionGate.isDestructive(step("Tap the icon", label: "Remove")))
        #expect(DestructiveActionGate.isDestructive(step("Tap the icon", identifier: "row.trash.button")))
    }

    @Test func testAnOrdinaryStepIsNotDestructive() {
        #expect(!DestructiveActionGate.isDestructive(step("Tap the Collection tab", label: "Collection", identifier: "tab.collection")))
    }

    @Test func testAStepWithoutATargetIsJudgedByItsIntent() {
        let bare = IRStep(id: "s", sourceStepNumber: 1, intent: "Delete the account", action: .tap)
        #expect(DestructiveActionGate.isDestructive(bare))
        #expect(!DestructiveActionGate.isDestructive(IRStep(id: "s", sourceStepNumber: 1, intent: "Open settings", action: .tap)))
    }

    @Test func testVerifyOnlyNeverNeedsAPerson() {
        // Looking at a screen that mentions "delete" changes nothing.
        #expect(!DestructiveActionGate.isDestructive(step("Verify the Delete button is shown", action: .verifyOnly, label: "Delete")))
    }

    // MARK: Row context

    private func element(_ id: String, role: String = "button", label: String?, identifier: String? = nil, y: Double, height: Double = 40) -> UIElementSnapshot {
        UIElementSnapshot(id: id, role: role, label: label, identifier: identifier, frame: ElementFrame(x: 0, y: y, width: 100, height: height))
    }

    private func screen(_ elements: [UIElementSnapshot]) -> Observation {
        Observation(snapshotID: "s", bundleID: "b", appState: .runningForeground, elements: elements)
    }

    @Test func testRowContextListsTheLabelsOnTheTargetsRow() {
        let observation = screen([
            element("t1", label: "Trash", identifier: "row.trash", y: 100),
            element("n1", role: "staticText", label: "ALPHA", y: 100),
            element("n2", role: "staticText", label: "Apple Inc.", y: 105),
            element("far", role: "staticText", label: "MSFT", y: 300)
        ])
        let context = DestructiveActionGate.rowContext(of: step("Delete", identifier: "row.trash"), in: observation)
        #expect(context.contains("'ALPHA'") && context.contains("'Apple Inc.'"))
        #expect(!context.contains("MSFT"), "another row is not this row")
        #expect(!context.contains("Trash"), "the target itself is not listed")
    }

    @Test func testRowContextFindsTheTargetByLabelWhenThereIsNoIdentifier() {
        let observation = screen([
            element("t1", label: "Remove", y: 50),
            element("n1", role: "staticText", label: "Row A", y: 50)
        ])
        #expect(DestructiveActionGate.rowContext(of: step("Remove", label: "Remove"), in: observation) == "'Row A'")
    }

    @Test func testRowContextUsesTheIdentifierToPickTheRightOfTwoIdenticalIcons() {
        let observation = screen([
            element("t1", label: "Trash", identifier: "trash.1", y: 100), element("a", role: "staticText", label: "Item One", y: 100),
            element("t2", label: "Trash", identifier: "trash.2", y: 200), element("b", role: "staticText", label: "Item Two", y: 200)
        ])
        #expect(DestructiveActionGate.rowContext(of: step("Delete", identifier: "trash.2"), in: observation) == "'Item Two'")
        #expect(DestructiveActionGate.rowContext(of: step("Delete", identifier: "trash.1"), in: observation) == "'Item One'")
    }

    @Test func testRowContextSaysSoWhenTheRowHasNoOtherLabel() {
        let observation = screen([element("t1", label: "Trash", y: 100), element("blank", role: "staticText", label: "", y: 100)])
        #expect(DestructiveActionGate.rowContext(of: step("Delete", label: "Trash"), in: observation) == "no other label on the row")
    }

    @Test func testRowContextIsUnknownWhenTheTargetIsNotOnScreenOrHasNoFrame() {
        let observation = screen([element("n", role: "staticText", label: "Other", y: 0)])
        #expect(DestructiveActionGate.rowContext(of: step("Delete", label: "Trash"), in: observation) == "unknown")
        let noFrame = screen([UIElementSnapshot(id: "t", role: "button", label: "Trash")])
        #expect(DestructiveActionGate.rowContext(of: step("Delete", label: "Trash"), in: noFrame) == "unknown")
        #expect(DestructiveActionGate.rowContext(of: IRStep(id: "s", sourceStepNumber: 1, intent: "Delete", action: .tap), in: observation) == "unknown")
    }

    @Test func testRowContextShowsAtMostSixLabels() {
        var elements = [element("t", label: "Trash", y: 100)]
        for index in 1...9 { elements.append(element("n\(index)", role: "staticText", label: "L\(index)", y: 100)) }
        let context = DestructiveActionGate.rowContext(of: step("Delete", label: "Trash"), in: screen(elements))
        #expect(context.split(separator: ",").count == 6)
    }

    @Test func testRowToleranceIsThirtyPointsBetweenCentres() {
        let observation = screen([
            element("t", label: "Trash", y: 100, height: 40),               // centre 120
            element("near", role: "staticText", label: "Near", y: 109),     // centre 129
            element("edge", role: "staticText", label: "Edge", y: 130)      // centre 150: 30 away, not on the row
        ])
        #expect(DestructiveActionGate.rowContext(of: step("Delete", label: "Trash"), in: observation) == "'Near'")
    }

    @Test func testTheTargetRoleMustMatch() {
        // A static text called "Trash" is not the trash button.
        let observation = screen([element("txt", role: "staticText", label: "Trash", y: 10)])
        #expect(DestructiveActionGate.rowContext(of: step("Delete", label: "Trash"), in: observation) == "unknown")
    }
}
