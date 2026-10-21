import SwiftUI
import AppKit

/// Turns the person's mouse and keyboard over the live simulator picture into taps, swipes, scrolls, text and keys. It reports view points and
/// plain values only; `OperateState` maps and runs them through the same device port as the agents. Clicking gives it the keyboard.
struct LiveInput: NSViewRepresentable {
    let onTap: (CGPoint) -> Void
    let onSwipe: (CGPoint, CGPoint) -> Void
    let onScroll: (String) -> Void
    let onText: (String) -> Void
    let onKey: (String) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) {
        view.onTap = onTap
        view.onSwipe = onSwipe
        view.onScroll = onScroll
        view.onText = onText
        view.onKey = onKey
    }

    final class InputView: NSView {
        var onTap: (CGPoint) -> Void = { _ in }
        var onSwipe: (CGPoint, CGPoint) -> Void = { _, _ in }
        var onScroll: (String) -> Void = { _ in }
        var onText: (String) -> Void = { _ in }
        var onKey: (String) -> Void = { _ in }
        private var start: CGPoint?
        private var accumulated = CGSize.zero
        private var lastScroll = Date.distantPast

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            start = convert(event.locationInWindow, from: nil)
        }

        override func mouseUp(with event: NSEvent) {
            guard let from = start else { return }
            start = nil
            let to = convert(event.locationInWindow, from: nil)
            if hypot(to.x - from.x, to.y - from.y) < 8 { onTap(to) } else { onSwipe(from, to) }
        }

        /// A wheel or trackpad scroll: one command per burst, in the direction the content should move.
        override func scrollWheel(with event: NSEvent) {
            accumulated.width += event.scrollingDeltaX
            accumulated.height += event.scrollingDeltaY
            guard Date().timeIntervalSince(lastScroll) > 0.4, max(abs(accumulated.width), abs(accumulated.height)) > 18 else { return }
            lastScroll = Date()
            // With natural scrolling a swipe up on the trackpad (negative delta) moves content up, which reveals what is further down.
            let direction = abs(accumulated.height) >= abs(accumulated.width) ? (accumulated.height < 0 ? "down" : "up") : (accumulated.width < 0 ? "right" : "left")
            accumulated = .zero
            onScroll(direction)
        }

        override func keyDown(with event: NSEvent) {
            let keys: [UInt16: String] = [36: "return", 76: "return", 51: "delete", 53: "escape", 48: "tab", 126: "up", 125: "down", 123: "left", 124: "right"]
            if let key = keys[event.keyCode] { onKey(key); return }
            // Shortcuts (⌘ and ⌃) are not typing.
            guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), let text = event.characters, !text.isEmpty else {
                super.keyDown(with: event)
                return
            }
            onText(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined())
        }
    }
}
