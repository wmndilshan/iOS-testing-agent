#if DEBUG
import AppKit

/// Saves a PNG of the main window once it has finished laying out (`--snapshot`). The window server's own composite is preferred, because it
/// includes the toolbar and sidebar; the in-process render of the content view is the fallback.
@MainActor
final class SnapshotCapture {
    private let path: String
    private let options: LaunchOptions
    private var ranWindowActions = false

    init(path: String, options: LaunchOptions) {
        self.path = path
        self.options = options
    }

    func captureWhenReady(attemptsLeft: Int) {
        for window in NSApplication.shared.windows {
            applySize(to: window)
            if options.has("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
            if options.has("--light") { window.appearance = NSAppearance(named: .aqua) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            guard let contentView = window.contentView else { continue }
            contentView.layoutSubtreeIfNeeded()
            guard contentView.bounds.width > 200, contentView.bounds.height > 200 else { continue }

            if !ranWindowActions {
                ranWindowActions = true
                if runWindowActions(in: window) {
                    // Give SwiftUI time to redraw after an appearance change, a toggled sidebar or a key press.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.captureWhenReady(attemptsLeft: attemptsLeft - 1) }
                    return
                }
            }
            let png = Self.windowServerPNG(window) ?? Self.contentPNG(contentView)
            guard let png else { continue }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("SNAPSHOT_SAVED:\(path)")
            } catch {
                print("ERROR: Failed to write snapshot: \(error)")
            }
            if options.has("--exit") { NSApplication.shared.terminate(nil) }
            return
        }
        guard attemptsLeft > 0 else {
            print("ERROR: Window or contentView not ready for snapshot after waiting")
            if options.has("--exit") { NSApplication.shared.terminate(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.captureWhenReady(attemptsLeft: attemptsLeft - 1) }
    }

    private func applySize(to window: NSWindow) {
        guard let size = options.value("--window-size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 else { return }
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: size[0], height: size[1]))
        if window.frame.size != frame.size { window.setFrame(NSRect(origin: window.frame.origin, size: frame.size), display: true) }
    }

    /// `--light`/`--dark`, `--collapse-sidebar` and `--send-keys` act through the real responder chain, as a person would.
    private func runWindowActions(in window: NSWindow) -> Bool {
        var acted = false
        if options.has("--light") || options.has("--dark") {
            let appearance = NSAppearance(named: options.has("--dark") ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            window.appearance = appearance
            acted = true
        }
        if options.has("--collapse-sidebar") {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            acted = true
        }
        if let keys = options.value("--send-keys") {
            let codes: [String: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "r": 15, ".": 47, "f": 3, "k": 40]
            for combo in keys.split(separator: ",") {
                let parts = combo.split(separator: "+").map(String.init)
                guard let key = parts.last else { continue }
                var flags: NSEvent.ModifierFlags = []
                if parts.contains("cmd") { flags.insert(.command) }
                if parts.contains("shift") { flags.insert(.shift) }
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: codes[key] ?? 0) {
                    let handled = window.performKeyEquivalent(with: event) || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
                    FileHandle.standardError.write(Data("KEY \(combo) handled=\(handled)\n".utf8))
                }
            }
            acted = true
        }
        return acted
    }

    private static func contentPNG(_ view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// The composited window from the window server (toolbar and sidebar included).
    private static func windowServerPNG(_ window: NSWindow) -> Data? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
#endif
