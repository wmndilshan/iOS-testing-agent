import Foundation

/// Remembers which `#number` each element was given, so a number keeps meaning the same element across reads (an agent holds `#4` through a diff).
/// Numbers restart at 1 when the screen is a different one.
public struct HandleBook: Sendable, Equatable {
    private var numbers: [String: Int] = [:]
    private var next = 1

    public init() {}

    mutating func handle(for key: String, occurrence: Int) -> Int {
        let full = "\(key)#\(occurrence)"
        if let number = numbers[full] { return number }
        numbers[full] = next
        next += 1
        return numbers[full] ?? 0
    }
}

/// Builds a `ScreenDigest` from an accessibility tree, renders it as the few lines an agent reads, and describes what changed since the last one.
/// Pure: the rules live here and are checked on captured trees, not on a device.
public enum ScreenDigestBuilder {
    public static let defaultLimit = 40
    public static let maxTextCharacters = 480

    private static let interactiveRoles: Set<String> = ["button", "textField", "secureTextField", "searchField", "textView", "switch", "slider", "stepper", "picker", "pickerWheel",
                                                         "segmentedControl", "link", "tab", "cell", "menuItem", "checkBox", "radioButton", "toggle", "backButton", "tabBarButton"]
    private static let overlayRoles = ["alert", "sheet", "popover", "dialog", "actionsheet"]

    // MARK: Building

    public static func build(elements: [UIElementSnapshot], window: ElementFrame?, version: Int, limit: Int = defaultLimit, handles: inout HandleBook) -> ScreenDigest {
        let width = Int(window?.width ?? 0), height = Int(window?.height ?? 0)
        func name(_ e: UIElementSnapshot) -> String { [e.label, e.value, e.identifier].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
        let visibleBounds = window.map { (x: $0.x, y: $0.y, w: $0.width, h: $0.height) }

        func onScreen(_ frame: ElementFrame?, hittable: Bool) -> Bool {
            guard hittable else { return false }
            guard let frame, let bounds = visibleBounds else { return true }
            let cx = frame.x + frame.width / 2, cy = frame.y + frame.height / 2
            return cx >= bounds.x && cx <= bounds.x + bounds.w && cy >= bounds.y && cy <= bounds.y + bounds.h
        }

        var seen = Set<String>()
        var occurrences: [String: Int] = [:]
        var controls: [ScreenDigest.Item] = [], texts: [ScreenDigest.Item] = []
        var keyboard = false
        var focused: String?
        var overlay: String?
        let candidates = elements.dropFirst().filter { !$0.isSecure || !($0.label ?? "").isEmpty }
        let sorted = candidates.sorted { a, b in
            let fa = a.frame, fb = b.frame
            if (fa?.y ?? 0) != (fb?.y ?? 0) { return (fa?.y ?? 0) < (fb?.y ?? 0) }
            return (fa?.x ?? 0) < (fb?.x ?? 0)
        }
        var controlFrames: [(label: String, frame: ElementFrame)] = []
        for element in sorted {
            let role = element.role
            if role.lowercased().contains("keyboard") { keyboard = true; continue }
            if overlay == nil, overlayRoles.contains(where: { role.lowercased().contains($0) }) { overlay = name(element) }
            if element.hasFocus == true, focused == nil { focused = name(element) }
            let label = name(element)
            guard !label.isEmpty, let frame = element.frame, frame.width > 0, frame.height > 0 else { continue }
            let isControl = interactiveRoles.contains(role) || (element.isHittable && element.identifier != nil && role != "staticText" && role != "image")
            let visible = onScreen(element.frame, hittable: element.isHittable)
            let key = "\(role)|\(element.identifier ?? "")|\(label)"
            let signature = "\(key)|\(Int(frame.x)),\(Int(frame.y))"
            guard seen.insert(signature).inserted else { continue }
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let item = ScreenDigest.Item(handle: 0, key: key, occurrence: occurrence, role: role, label: String(label.prefix(60)), identifier: element.identifier.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) },
                                         value: element.value.flatMap { $0.isEmpty || $0 == label ? nil : String($0.prefix(40)) },
                                         x: Int(frame.x + frame.width / 2), y: Int(frame.y + frame.height / 2), width: Int(frame.width), height: Int(frame.height),
                                         isOnScreen: visible, isEnabled: element.isEnabled, isSelected: element.isSelected == true)
            if isControl {
                controls.append(item)
                controlFrames.append((label, frame))
            } else if role == "staticText" || role == "textView" {
                texts.append(item)
            }
        }
        // A piece of text that sits inside a control and says what the control says adds nothing: the control already carries it.
        texts = texts.filter { text in
            !controlFrames.contains { control in
                control.label == text.label || (control.label.contains(text.label) && contains(control.frame, x: text.x, y: text.y))
            }
        }
        // On-screen controls first (a control scrolled out of view can only be reached by scrolling), then the rest, each in reading order.
        let onScreenControls = controls.filter(\.isOnScreen), offScreenControls = controls.filter { !$0.isOnScreen }
        let ordered = onScreenControls + offScreenControls
        let shownControls = Array(ordered.prefix(limit))
        let shownTexts = Array(texts.filter(\.isOnScreen).prefix(max(0, min(14, limit - shownControls.count / 2))))
        func numbered(_ items: [ScreenDigest.Item]) -> [ScreenDigest.Item] {
            items.map { item in
                ScreenDigest.Item(handle: handles.handle(for: item.key, occurrence: item.occurrence), key: item.key, occurrence: item.occurrence, role: item.role, label: item.label,
                                  identifier: item.identifier, value: item.value, x: item.x, y: item.y, width: item.width, height: item.height, isOnScreen: item.isOnScreen,
                                  isEnabled: item.isEnabled, isSelected: item.isSelected)
            }
        }
        return ScreenDigest(version: version, width: width, height: height, keyboardVisible: keyboard, focusedField: focused, overlay: overlay, controls: numbered(shownControls),
                            texts: numbered(shownTexts), omittedControls: max(0, ordered.count - shownControls.count), omittedTexts: max(0, texts.filter(\.isOnScreen).count - shownTexts.count))
    }

    private static func contains(_ frame: ElementFrame, x: Int, y: Int) -> Bool {
        Double(x) >= frame.x && Double(x) <= frame.x + frame.width && Double(y) >= frame.y && Double(y) <= frame.y + frame.height
    }

    // MARK: Reading it

    /// The digest as text: a header with the state that matters, the controls one per line, then the readable text in one paragraph.
    public static func render(_ digest: ScreenDigest, query: String? = nil) -> String {
        var header = "Screen \(digest.width)x\(digest.height) (v\(digest.version))"
        if digest.keyboardVisible { header += " · keyboard up" }
        if let focus = digest.focusedField { header += " · typing in “\(focus)”" }
        if let overlay = digest.overlay { header += " · covered by “\(overlay)”" }
        let needle = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let controls = needle.isEmpty ? digest.controls : digest.controls.filter { matches($0, needle) }
        let texts = needle.isEmpty ? digest.texts : digest.texts.filter { matches($0, needle) }
        var lines = [header]
        if !controls.isEmpty { lines.append("Controls:"); lines += controls.map(line) }
        if digest.omittedControls > 0, needle.isEmpty { lines.append("… \(digest.omittedControls) more controls (use find, or read_screen with a query)") }
        if !texts.isEmpty {
            var joined = texts.map { "“\($0.label)”" }.joined(separator: ", ")
            if joined.count > maxTextCharacters { joined = String(joined.prefix(maxTextCharacters)) + "…" }
            lines.append("Text: " + joined + (digest.omittedTexts > 0 && needle.isEmpty ? " … +\(digest.omittedTexts)" : ""))
        }
        if controls.isEmpty && texts.isEmpty { lines.append(needle.isEmpty ? "Nothing readable on screen: this screen does not expose its accessibility tree (some system screens). Take a screenshot and read it, or use look." : "Nothing on screen matches “\(query ?? "")”.") }
        return lines.joined(separator: "\n")
    }

    /// One element as a line: `#4 button “Settings” id=open-settings (140,222)`.
    public static func line(_ item: ScreenDigest.Item) -> String {
        var parts = ["#\(item.handle)", item.role, "“\(item.label)”"]
        if let identifier = item.identifier, identifier != item.label { parts.append("id=\(identifier)") }
        if let value = item.value { parts.append("=\(value)") }
        parts.append("(\(item.x),\(item.y))")
        if item.isSelected { parts.append("[selected]") }
        if !item.isEnabled { parts.append("[disabled]") }
        if !item.isOnScreen { parts.append("[off-screen: scroll]") }
        return parts.joined(separator: " ")
    }

    private static func matches(_ item: ScreenDigest.Item, _ needle: String) -> Bool {
        [item.label, item.identifier ?? "", item.value ?? "", item.role].contains { $0.lowercased().contains(needle) }
    }

    // MARK: What changed

    /// The difference from the previous digest, as text, or nil when so much changed that the whole screen is the better answer.
    public static func diff(from previous: ScreenDigest, to current: ScreenDigest) -> String? {
        func occurrences(_ items: [ScreenDigest.Item]) -> [String: ScreenDigest.Item] {
            var counts: [String: Int] = [:]
            var result: [String: ScreenDigest.Item] = [:]
            for item in items { let n = counts[item.key, default: 0]; counts[item.key] = n + 1; result["\(item.key)#\(n)"] = item }
            return result
        }
        let before = occurrences(previous.controls + previous.texts), after = occurrences(current.controls + current.texts)
        let added = after.filter { before[$0.key] == nil }.values.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        let removed = before.filter { after[$0.key] == nil }.values.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        let changed = after.compactMap { key, item -> (ScreenDigest.Item, ScreenDigest.Item)? in
            guard let old = before[key], old.value != item.value || old.isSelected != item.isSelected || old.isEnabled != item.isEnabled else { return nil }
            return (old, item)
        }
        let total = max(before.count, after.count, 1)
        // A different screen: say so in full rather than as a long list of everything that is new.
        guard Double(added.count + removed.count) < max(3, Double(total) * 0.6) else { return nil }
        if added.isEmpty && removed.isEmpty && changed.isEmpty && previous.keyboardVisible == current.keyboardVisible && previous.overlay == current.overlay {
            return "Screen unchanged (v\(current.version)): \(current.controls.count) controls."
        }
        var lines = ["Changed since the last read (v\(current.version)): \(added.count) new, \(removed.count) gone, \(changed.count) changed; \(current.controls.count) controls now."]
        if previous.keyboardVisible != current.keyboardVisible { lines.append(current.keyboardVisible ? "+ keyboard up" : "- keyboard gone") }
        if previous.overlay != current.overlay { lines.append(current.overlay.map { "+ covered by “\($0)”" } ?? "- overlay gone") }
        if let focus = current.focusedField, focus != previous.focusedField { lines.append("typing in “\(focus)”") }
        lines += added.prefix(24).map { "+ " + line($0) }
        lines += removed.prefix(12).map { "- \($0.role) “\($0.label)”" }
        lines += changed.prefix(12).map { old, new in "~ \(new.role) “\(new.label)”: \(old.value ?? "(none)") → \(new.value ?? "(none)")" + (old.isSelected != new.isSelected ? (new.isSelected ? " [now selected]" : " [no longer selected]") : "") }
        return lines.joined(separator: "\n")
    }
}
