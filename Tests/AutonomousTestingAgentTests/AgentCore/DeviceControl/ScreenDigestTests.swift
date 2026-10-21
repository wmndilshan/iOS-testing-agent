import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

private func element(_ id: Int, _ role: String, _ label: String?, identifier: String? = nil, value: String? = nil, x: Double = 0, y: Double = 0, w: Double = 100, h: Double = 40,
                     hittable: Bool = true, enabled: Bool = true, selected: Bool? = nil, focus: Bool? = nil) -> UIElementSnapshot {
    UIElementSnapshot(id: "elem_\(id)", role: role, label: label, identifier: identifier, value: value, isEnabled: enabled, isHittable: hittable, isSelected: selected, hasFocus: focus,
                      frame: ElementFrame(x: x, y: y, width: w, height: h))
}

private let window = ElementFrame(x: 0, y: 0, width: 402, height: 874)
private let app = element(0, "application", "Demo", x: 0, y: 0, w: 402, h: 874)

private func digest(_ elements: [UIElementSnapshot], version: Int = 1, limit: Int = 40, book: inout HandleBook) -> ScreenDigest {
    ScreenDigestBuilder.build(elements: [app] + elements, window: window, version: version, limit: limit, handles: &book)
}

@Suite("Screen digest")
struct ScreenDigestTests {
    @Test("Controls and readable text are kept in reading order; unnamed and decorative nodes are dropped; the application root is skipped")
    func filtering() {
        var book = HandleBook()
        let d = digest([
            element(1, "button", "Settings", identifier: "open-settings", x: 100, y: 200, w: 80, h: 44),
            element(2, "other", nil, x: 0, y: 100, w: 402, h: 700),
            element(3, "staticText", "Welcome back", x: 20, y: 60, w: 200, h: 30),
            element(4, "image", "logo", x: 20, y: 10, w: 40, h: 40),
            element(5, "textField", "Search", value: "apple", x: 20, y: 120, w: 300, h: 44),
        ], book: &book)
        #expect(d.controls.map(\.label) == ["Search", "Settings"], "top to bottom")
        #expect(d.texts.map(\.label) == ["Welcome back"])
        #expect(d.controls.first { $0.label == "Search" }?.value == "apple")
        #expect(d.width == 402 && d.height == 874)
    }

    @Test("Text that sits inside a control and repeats its label is not listed again")
    func merging() {
        var book = HandleBook()
        let d = digest([
            element(1, "cell", "Wi-Fi, Home", x: 0, y: 300, w: 402, h: 60),
            element(2, "staticText", "Wi-Fi, Home", x: 20, y: 310, w: 200, h: 20),
            element(3, "staticText", "Home", x: 250, y: 310, w: 60, h: 20),
            element(4, "staticText", "A separate note", x: 20, y: 500, w: 200, h: 20),
        ], book: &book)
        #expect(d.controls.map(\.label) == ["Wi-Fi, Home"])
        #expect(d.texts.map(\.label) == ["A separate note"])
    }

    @Test("Keyboard, the field being typed in, and an alert covering the screen are reported")
    func state() {
        var book = HandleBook()
        let d = digest([
            element(1, "textField", "Address", x: 20, y: 800, w: 300, h: 44, focus: true),
            element(2, "keyboard", "Keyboard", x: 0, y: 600, w: 402, h: 274),
            element(3, "alert", "Session expired", x: 50, y: 300, w: 300, h: 200),
        ], book: &book)
        #expect(d.keyboardVisible && d.focusedField == "Address" && d.overlay == "Session expired")
        let text = ScreenDigestBuilder.render(d)
        #expect(text.contains("keyboard up") && text.contains("typing in “Address”") && text.contains("covered by “Session expired”"))
    }

    @Test("The line limit keeps on-screen controls first and says how many were left out")
    func limit() {
        var book = HandleBook()
        var elements = (1...60).map { element($0, "button", "Item \($0)", x: 10, y: Double($0 * 12), w: 80, h: 10) }
        elements.append(element(99, "button", "Far below", x: 10, y: 2000, w: 80, h: 40, hittable: false))
        let d = digest(elements, limit: 10, book: &book)
        #expect(d.controls.count == 10 && d.omittedControls == 51)
        #expect(!d.controls.contains { $0.label == "Far below" } && ScreenDigestBuilder.render(d).contains("… 51 more controls"))
    }

    @Test("A control scrolled out of view is marked so the agent scrolls to it")
    func offScreen() {
        var book = HandleBook()
        let d = digest([element(1, "button", "Sign out", x: 10, y: 1500, w: 80, h: 40, hittable: false)], book: &book)
        #expect(ScreenDigestBuilder.render(d).contains("[off-screen: scroll]"))
    }

    @Test("A number keeps meaning the same element across reads, new elements get new numbers, and an identical twin gets its own")
    func stableHandles() {
        var book = HandleBook()
        let first = digest([element(1, "button", "Save", x: 10, y: 100), element(2, "button", "Save", x: 10, y: 200), element(3, "button", "Cancel", x: 10, y: 300)], book: &book)
        #expect(first.controls.map(\.handle) == [1, 2, 3])
        // Cancel moves up and a new button appears first: the numbers do not shuffle.
        let second = digest([element(9, "button", "Help", x: 10, y: 50), element(1, "button", "Save", x: 10, y: 100), element(2, "button", "Save", x: 10, y: 200), element(3, "button", "Cancel", x: 10, y: 260)], version: 2, book: &book)
        #expect(second.controls.first { $0.label == "Help" }?.handle == 4)
        #expect(second.controls.filter { $0.label == "Save" }.map(\.handle) == [1, 2])
        #expect(second.controls.first { $0.label == "Cancel" }?.handle == 3)
    }

    @Test("A query shows only the matching elements, and says so when nothing matches")
    func query() {
        var book = HandleBook()
        let d = digest([element(1, "button", "Settings", x: 10, y: 100), element(2, "button", "Orders", x: 10, y: 200)], book: &book)
        #expect(ScreenDigestBuilder.render(d, query: "order").contains("Orders") && !ScreenDigestBuilder.render(d, query: "order").contains("Settings"))
        #expect(ScreenDigestBuilder.render(d, query: "zebra").contains("Nothing on screen matches “zebra”"))
    }

    @Test("A diff lists what appeared, went and changed; an unchanged screen is one line; a different screen returns nil")
    func diffs() {
        var book = HandleBook()
        let before = digest([element(1, "button", "Done", x: 10, y: 100), element(2, "textField", "Address", value: "a", x: 10, y: 200), element(3, "button", "Back", x: 10, y: 300)], book: &book)
        let same = digest([element(1, "button", "Done", x: 10, y: 100), element(2, "textField", "Address", value: "a", x: 10, y: 200), element(3, "button", "Back", x: 10, y: 300)], version: 2, book: &book)
        #expect(ScreenDigestBuilder.diff(from: before, to: same)?.hasPrefix("Screen unchanged") == true)

        let after = digest([element(1, "button", "Done", x: 10, y: 100), element(2, "textField", "Address", value: "ab", x: 10, y: 200), element(4, "button", "Share", x: 10, y: 400)], version: 3, book: &book)
        let changes = ScreenDigestBuilder.diff(from: before, to: after) ?? ""
        #expect(changes.contains("1 new, 1 gone, 1 changed"))
        #expect(changes.contains("+ #4 button “Share”") && changes.contains("- button “Back”") && changes.contains("~ textField “Address”: a → ab"))

        let other = digest([element(7, "button", "Buy", x: 10, y: 100), element(8, "button", "Pay", x: 10, y: 200), element(9, "button", "Cart", x: 10, y: 300)], version: 4, book: &book)
        #expect(ScreenDigestBuilder.diff(from: before, to: other) == nil)
    }
}
