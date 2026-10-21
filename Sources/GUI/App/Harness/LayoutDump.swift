#if DEBUG
import AppKit

/// Harness only (`--dump-layout[=seconds]`): prints the window and the big AppKit containers with their frames, so a layout that has grown
/// past the window can be measured without a screenshot.
enum LayoutDump {
    @MainActor
    static func schedule(from options: LaunchOptions) {
        scheduleSeries(from: options)
        guard options.has("--dump-layout") else { return }
        let seconds = options.value("--dump-layout").flatMap(Double.init) ?? 10
        print("LAYOUT scheduled in \(seconds)s"); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { printLayout() }
    }

    /// `--dump-layout-series=SECONDS`: one line per second with the split view and window heights, to see whether a layout grows over time.
    @MainActor
    private static func scheduleSeries(from options: LaunchOptions) {
        guard let total = options.value("--dump-layout-series").flatMap(Int.init) else { return }
        for second in 1...total {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(second)) {
                guard let window = NSApp.windows.first(where: { $0.contentView != nil }), let split = findSplit(in: window.contentView!) else { return }
                print("SERIES t=\(second)s window=\(Int(window.contentView!.frame.height)) split=\(Int(split.frame.height))"); fflush(stdout)
            }
        }
    }

    @MainActor private static func findSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews { if let found = findSplit(in: sub) { return found } }
        return nil
    }

    @MainActor
    static func printLayout() {
        defer { fflush(stdout) }
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { print("LAYOUT no window"); return }
        print("LAYOUT visible=\(window.isVisible) miniaturized=\(window.isMiniaturized) occlusion=\(window.occlusionState.contains(.visible)) screen=\(window.screen.map { frame($0.frame) } ?? "none")")
        print("LAYOUT keyboard active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) isKey=\(window.isKeyWindow) canBecomeKey=\(window.canBecomeKey) firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        print("LAYOUT window \(frame(window.frame)) content \(frame(window.contentView!.frame)) minSize \(window.contentMinSize)")
        func walk(_ view: NSView, depth: Int) {
            let name = String(describing: type(of: view))
            let interesting = view is NSSplitView || view is NSScrollView || view is NSTableView || name.contains("HostingView") || name.contains("SplitView")
            if interesting {
                let overflow = view.frame.height > window.contentView!.frame.height + 1
                print("LAYOUT \(String(repeating: "  ", count: depth))\(name) \(frame(view.frame))\(overflow ? "  <-- TALLER THAN WINDOW" : "")")
            }
            for sub in view.subviews { walk(sub, depth: depth + (interesting ? 1 : 0)) }
        }
        walk(window.contentView!, depth: 0)
    }

    private static func frame(_ r: CGRect) -> String { "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height)))" }
}
#endif
