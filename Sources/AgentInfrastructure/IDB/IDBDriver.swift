import Foundation
import AgentCore

/// A driver that observes through `idb ui describe-all` and acts through `idb ui tap/swipe/text`.
///
/// It is the live implementation of the `DeviceDriver` port, so every call still arrives through
/// `ToolRegistry` after approval. Guarantees: every action names a snapshot and element from the
/// latest observation (anything else is a stale-snapshot error), disabled, off-screen and ambiguous targets are refused,
/// typed text never reaches a result, and input is refused unless live execution is enabled.
/// Observation is read-only and works in either mode.
public actor IDBDriver: LiveExecutionControllable, AppForegrounding {
    private let client: IDBClient
    private let udid: String
    private var liveEnabled: Bool
    private var latestSnapshot: Observation?
    private var launchedForRun: Set<String> = []
    private var currentBundleID = ""
    /// Set once a screen needed the `axbridge` backend; later reads start there instead of paying for a thin default read first.
    private var preferBridge = false
    private var applications: [String: (name: String, pid: Int?)] = [:]

    /// Time for the UI to settle after an input before the caller observes again. Short, because the case runner then polls until the screen
    /// stops changing; a long fixed wait here is paid on every action.
    private let settleSeconds: Double = 0.4

    init(client: IDBClient, simulatorUDID: String, isLiveExecutionEnabled: Bool) {
        self.client = client
        self.udid = simulatorUDID
        self.liveEnabled = isLiveExecutionEnabled
    }

    public var isLiveExecutionEnabled: Bool { liveEnabled }

    /// `simctl launch` starts a stopped app and brings a running one to the front without restarting it.
    public func bringToForeground(bundleID: String) async {
        await client.launchApp(bundleID)
    }
    public func setLiveExecution(enabled: Bool) { liveEnabled = enabled }

    // MARK: - Observation

    public func captureObservation(bundleID: String) async throws -> Observation {
        // The reason the last read failed, so "no accessibility tree" says why (a hung idb, a lockfile, no companion) instead of nothing.
        let failure = FailureNote()
        func read(_ options: [String] = []) async -> [[String: Any]] {
            do {
                let data = try await client.run(["ui", "describe-all"], options: options)
                return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            } catch {
                failure.set(error.localizedDescription)
                return []
            }
        }
        var nodes = preferBridge ? await read(["--api", "axbridge"]) : await read()
        // A thin tree means the app's accessibility is not awake yet (only the root element) or its content lives in another
        // process (web pages). The `axbridge` backend wakes the app (its first request may time out) and sees across processes,
        // so read with it and keep whichever tree has more elements.
        if nodes.count < 12 {
            let bridged = await read(["--api", "axbridge"])
            let again = bridged.isEmpty ? await read(["--api", "axbridge"]) : bridged
            let ax = await read()
            nodes = [nodes, again, ax].max { $0.count < $1.count } ?? nodes
            preferBridge = again.count > ax.count
        }
        // Only a presented sheet (a popover, or a second remote-hosted view besides the page itself) reports frames local to the
        // sheet; the page's own remote view is already in screen coordinates.
        let types = nodes.compactMap { $0["type"] as? String }
        if types.contains("Popover") || types.filter({ $0 == "RemoteElement" }).count >= 2 { nodes = await correctingRemoteFrames(nodes) }
        if nodes.count <= 1 {
            await client.cycleForeground(to: bundleID)
            nodes = await read()
        }
        guard !nodes.isEmpty else {
            throw DriverError.observationFailed("idb returned no accessibility tree." + (failure.value.map { " Last error: \($0.suffix(220))" } ?? ""))
        }
        guard let root = nodes.first(where: { ($0["type"] as? String) == "Application" }) else {
            throw DriverError.observationFailed("idb tree has no application element.")
        }
        // The expected app is in front when the root element carries its display name or its process ID. The label alone is
        // not enough: it is empty while a sheet or drawer is presented over the app.
        let observedName = root["AXLabel"] as? String
        let observedPID = Self.processID(root["pid"])
        var known = try await application(for: bundleID, refresh: false)
        if !Self.isInFront(known, name: observedName, pid: observedPID) {
            known = try await application(for: bundleID, refresh: true)
            guard Self.isInFront(known, name: observedName, pid: observedPID) else {
                throw DriverError.wrongApplication(expected: bundleID, observed: observedName ?? "unlabelled application (pid \(observedPID.map(String.init) ?? "unknown"))", verdict: .notForeground)
            }
        }
        let window = IDBAccessibilityTree.frame(of: root)
        // Layout containers (nameless views and glass/material layers) carry nothing a test can target, and on a busy screen they
        // push the real controls past the element cap. Keep the root, anything with a name, identifier or value, and controls.
        let controlTypes: Set<String> = ["Application", "Button", "TextField", "SecureTextField", "TextView", "Switch", "Slider", "Link", "Cell", "Tab", "SearchField", "Picker", "Stepper"]
        func text(_ node: [String: Any], _ key: String) -> Bool { !((node[key] as? String) ?? "").isEmpty }
        let kept = nodes.enumerated().filter { index, node in
            index == 0 || text(node, "AXLabel") || text(node, "AXUniqueId") || text(node, "AXValue") || controlTypes.contains(node["type"] as? String ?? "")
        }.map(\.element)
        let all = kept.enumerated().map { IDBAccessibilityTree.element(from: $1, index: $0, window: window) }
        // On-screen controls first, so the cap never hides the toolbar of a long page; off-screen ones (needed to scroll to them) follow.
        let visible = all.filter { $0.id == "elem_1" || $0.isHittable }
        let hidden = all.filter { $0.id != "elem_1" && !$0.isHittable }
        let elements = Array(visible.prefix(240)) + Array(hidden.prefix(60))
        let sanitized = ObservationFilter.sanitizeWithTruncation(elements: elements, maxElements: 300)
        var observation = Observation(snapshotID: "snap_" + UUID().uuidString.prefix(8), bundleID: bundleID, appState: .runningForeground,
                                      source: .accessibilityTree, elements: sanitized.elements, isTruncated: sanitized.isTruncated)
        observation.simulatorUDID = udid
        observation.application = ObservedApplication(bundleID: bundleID, bundleSource: "environment", foreground: true,
                                                      windowWidth: window.map { Int($0.width) }, windowHeight: window.map { Int($0.height) },
                                                      runID: UUID().uuidString, runnerProtocol: "idb")
        latestSnapshot = observation
        currentBundleID = bundleID
        return observation
    }

    public func captureScreenshot(reason: String) async throws -> (imagePath: String, observation: Observation?) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("idb_\(UUID().uuidString.prefix(8)).png").path
        try await client.screenshot(to: path)
        return (path, nil)
    }

    // MARK: - Input

    public func tap(snapshotID: String, elementID: String) async throws -> ToolResult {
        try await tapElement(snapshotID, elementID, holdSeconds: nil, summary: "tapped")
    }

    public func selectTab(snapshotID: String, elementID: String) async throws -> ToolResult {
        try await tapElement(snapshotID, elementID, holdSeconds: nil, summary: "selected tab")
    }

    public func doubleTap(snapshotID: String, elementID: String) async throws -> ToolResult {
        let target = try actionable(snapshotID, elementID)
        let point = try Self.center(of: target)
        try await client.run(["ui", "tap"], positional: [Self.coordinate(point.x), Self.coordinate(point.y)])
        try await client.run(["ui", "tap"], positional: [Self.coordinate(point.x), Self.coordinate(point.y)])
        return await done("double tapped \(Self.describe(target))")
    }

    public func longPress(snapshotID: String, elementID: String, durationSeconds: Double) async throws -> ToolResult {
        try await tapElement(snapshotID, elementID, holdSeconds: durationSeconds, summary: "long pressed")
    }

    public func swipe(snapshotID: String, elementID: String, direction: ScrollDirection) async throws -> ToolResult {
        try await swipeWithin(snapshotID, elementID, finger: direction, summary: "swiped \(direction.rawValue) on", acrossWindow: nil)
    }

    public func scroll(snapshotID: String, containerID: String, direction: ScrollDirection) async throws -> ToolResult {
        // Scrolling down reveals content below, which takes a finger moving up.
        try await swipeWithin(snapshotID, containerID, finger: direction.opposite, summary: "scrolled \(direction.rawValue) on", acrossWindow: true)
    }

    public func dragAndDrop(snapshotID: String, sourceElementID: String, destinationElementID: String, holdDurationSeconds: Double) async throws -> ToolResult {
        let source = try actionable(snapshotID, sourceElementID)
        let destination = try actionable(snapshotID, destinationElementID)
        let from = try Self.center(of: source)
        let to = try Self.center(of: destination)
        try await client.run(["ui", "swipe"], options: ["--duration", Self.format(max(holdDurationSeconds, 0.5))],
                             positional: [Self.coordinate(from.x), Self.coordinate(from.y), Self.coordinate(to.x), Self.coordinate(to.y)])
        return await done("dragged \(Self.describe(source)) to \(Self.describe(destination))")
    }

    public func typeText(snapshotID: String, elementID: String, text: String) async throws -> ToolResult {
        let target = try actionable(snapshotID, elementID)
        let point = await settledCenter(of: target)
        try await client.run(["ui", "tap"], positional: [Self.coordinate(point.x), Self.coordinate(point.y)])
        try await Task.sleep(nanoseconds: 500_000_000)
        // A field can already hold text (a remembered username): typing would insert into it. Typing replaces what is there, so the
        // cursor goes to the end and the old characters are deleted first. Extra Backspace presses on a shorter text do no harm.
        if let existing = target.value, !existing.isEmpty, let frame = target.frame {
            try await client.run(["ui", "tap"], positional: [Self.coordinate(frame.x + frame.width - 8), Self.coordinate(frame.y + frame.height / 2)])
            try await Task.sleep(nanoseconds: 400_000_000)
            try await client.run(["ui", "key-sequence"], positional: Array(repeating: "42", count: min(existing.count + 4, 120)))
        }
        try await client.run(["ui", "text"], positional: [text])
        // The text can fail to land (the form moved, or the tap did not focus the field). A plain field shows what it holds, so look: if the
        // text is nowhere on screen, focus the field again and type once more. A secure field shows dots, so it cannot be checked this way.
        if !target.isSecure, !text.isEmpty, await !screenShows(text) {
            try await client.run(["ui", "tap"], positional: [Self.coordinate(point.x), Self.coordinate(point.y)])
            try await Task.sleep(nanoseconds: 700_000_000)
            try await client.run(["ui", "text"], positional: [text])
        }
        return await done("typed \(text.count) characters into \(Self.describe(target)) (text redacted)")
    }

    /// True when some element on screen carries `text` as its value or label (a text field's label is its content once it holds text).
    private func screenShows(_ text: String) async -> Bool {
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let data = try? await client.run(["ui", "describe-all"]), let nodes = IDBAccessibilityTree.nodes(from: data) else { return true }
        return nodes.contains { node in
            [node["AXValue"], node["AXLabel"]].contains { ($0 as? String)?.contains(text) == true }
        }
    }

    /// Where to tap a field that text goes into. The keyboard of the previous field may still be sliding, which moves the form: the
    /// recorded frame is then stale and the tap lands on the previous field, so the text goes there. The field is read again until
    /// its frame stops moving, and that position is used. Without a stable match the recorded frame stands.
    private func settledCenter(of target: UIElementSnapshot) async -> (x: Double, y: Double) {
        let recorded = (try? Self.center(of: target)) ?? (0, 0)
        guard let identifier = target.identifier, !identifier.isEmpty else { return recorded }
        func currentFrame() async -> ElementFrame? {
            guard let data = try? await client.run(["ui", "describe-all"], options: ["--api", "axbridge"]),
                  let nodes = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
            let matches = nodes.filter { ($0["AXUniqueId"] as? String) == identifier }
            return matches.count == 1 ? IDBAccessibilityTree.frame(of: matches[0]) : nil
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        var last = await currentFrame()
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 350_000_000)
            let now = await currentFrame()
            guard let a = last, let b = now else { return recorded }
            if abs(a.x - b.x) < 1, abs(a.y - b.y) < 1 { return (b.x + b.width / 2, b.y + b.height / 2) }
            last = now
        }
        return recorded
    }

    /// Presses the Return key (HID usage 40): submits a typed address or search, and closes an on-screen keyboard.
    public func dismissKeyboard(snapshotID: String, elementID: String) async throws -> ToolResult {
        let target = try actionable(snapshotID, elementID)
        try await client.run(["ui", "key"], positional: ["40"])
        return await done("pressed Return for \(Self.describe(target))")
    }

    /// Empties a text field: tap at its right end so the cursor lands after the text, then press Backspace (HID usage 42) once per
    /// character plus a few spare. A field's visible text is the only length known, so the spare presses cover a stale reading.
    public func clearText(snapshotID: String, elementID: String) async throws -> ToolResult {
        let target = try actionable(snapshotID, elementID)
        guard let frame = target.frame else { throw DriverError.elementNotHittable(elementID) }
        let length = min(max((target.value ?? "").count, 1) + 4, 120)
        try await client.run(["ui", "tap"], positional: [Self.coordinate(frame.x + frame.width - 8), Self.coordinate(frame.y + frame.height / 2)])
        try await Task.sleep(nanoseconds: 400_000_000)
        try await client.run(["ui", "key-sequence"], positional: Array(repeating: "42", count: length))
        return await done("cleared \(Self.describe(target)) (\(length) Backspace presses)")
    }

    // MARK: - Read-only

    public func getElementDetails(snapshotID: String, elementID: String) async throws -> ToolResult {
        let element = try bound(snapshotID, elementID)
        var payload: [String: AnyCodableValue] = [
            "id": .string(element.id), "role": .string(element.role), "isEnabled": .bool(element.isEnabled),
            "isHittable": .bool(element.isHittable), "isSecure": .bool(element.isSecure)
        ]
        if let label = element.label { payload["label"] = .string(label) }
        if let identifier = element.identifier { payload["identifier"] = .string(identifier) }
        if let frame = element.frame {
            payload["frame"] = .dictionary(["x": .double(frame.x), "y": .double(frame.y), "width": .double(frame.width), "height": .double(frame.height)])
        }
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "Details of \(Self.describe(element)).", payload: payload)
    }

    public func inspectElements(snapshotID: String, expectedElements: [ScenarioExpectedElement]) async throws -> ToolResult {
        guard let current = latestSnapshot, current.snapshotID == snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: latestSnapshot?.snapshotID ?? "none")
        }
        let fresh = try await captureObservation(bundleID: currentBundleID)
        var failures: [String] = []
        for expected in expectedElements {
            guard let match = fresh.elements.first(where: { expected.matches(element: $0) }) else {
                failures.append("\(expected.role) (\(expected.identifier ?? expected.label ?? "unnamed")): Missing from hierarchy.")
                continue
            }
            let (valid, reason) = expected.validate(against: match)
            if !valid { failures.append("\(expected.role) (\(expected.identifier ?? expected.label ?? "unnamed")): \(reason)") }
        }
        guard failures.isEmpty else { throw DriverError.actionFailed("Inspection assertions failed: \(failures.joined(separator: "; "))") }
        return ToolResult(callID: UUID().uuidString, status: .success,
                          summary: "idb inspection verified \(expectedElements.count) expected elements without state alteration.", observation: fresh)
    }

    // MARK: - Resolution

    /// The element named by an action, bound to the latest snapshot exactly as the port requires.
    private func bound(_ snapshotID: String, _ elementID: String) throws -> UIElementSnapshot {
        guard let current = latestSnapshot, current.snapshotID == snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: latestSnapshot?.snapshotID ?? "none")
        }
        guard let element = current.elements.first(where: { $0.id == elementID }) else { throw DriverError.elementNotFound(elementID) }
        return element
    }

    /// An element that may receive input: live execution on, enabled, on screen and not ambiguous.
    /// `checksTwins` is off when the element is only a place to scroll: a scroll needs the container's frame, not a unique reference to it, and
    /// scroll containers rarely have a label or identifier (so every one of them would look like the other's twin).
    private func actionable(_ snapshotID: String, _ elementID: String, checksTwins: Bool = true) throws -> UIElementSnapshot {
        guard liveEnabled else { throw DriverError.unsupportedCapability("the idb driver sends device input only when live execution is enabled") }
        let element = try bound(snapshotID, elementID)
        if checksTwins, (element.identifier ?? "").isEmpty, let current = latestSnapshot {
            let twins = current.elements.filter { $0.role == element.role && $0.label == element.label && ($0.identifier ?? "").isEmpty }
            if twins.count > 1 { throw DriverError.ambiguousElement(elementID, count: twins.count) }
        }
        guard element.isEnabled else { throw DriverError.elementDisabled(elementID) }
        guard element.isHittable else { throw DriverError.elementNotHittable(elementID) }
        return element
    }

    private func tapElement(_ snapshotID: String, _ elementID: String, holdSeconds: Double?, summary: String) async throws -> ToolResult {
        let target = try actionable(snapshotID, elementID)
        let point = try Self.center(of: target)
        let options = holdSeconds.map { ["--duration", Self.format($0)] } ?? []
        try await client.run(["ui", "tap"], options: options, positional: [Self.coordinate(point.x), Self.coordinate(point.y)])
        // A switch or checkbox that did not change was not toggled, whatever idb said about the tap: say so instead of letting the step pass.
        if holdSeconds == nil, ToggleCheck.isToggle(target) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let data = try? await client.run(["ui", "describe-all"]), let nodes = IDBAccessibilityTree.nodes(from: data) {
                let window = IDBAccessibilityTree.frame(of: nodes[0])
                let elements = nodes.enumerated().map { IDBAccessibilityTree.element(from: $1, index: $0, window: window) }
                if let reason = ToggleCheck.unchanged(before: target, after: elements) {
                    throw DriverError.actionFailed("The tap did not toggle \(Self.describe(target)): \(reason).")
                }
            }
        }
        return await done("\(summary) \(Self.describe(target))")
    }

    private func swipeWithin(_ snapshotID: String, _ elementID: String, finger: ScrollDirection, summary: String, acrossWindow requested: Bool?) async throws -> ToolResult {
        // A scroll (`acrossWindow: true`) only needs the container's frame, so look-alike unlabeled containers are not ambiguous for it.
        let target = try actionable(snapshotID, elementID, checksTwins: requested != true)
        guard let frame = target.frame else { throw DriverError.elementNotHittable(elementID) }
        let center = try Self.center(of: target)
        let window = latestSnapshot?.application
        let width = Double(window?.windowWidth ?? 402), height = Double(window?.windowHeight ?? 874)
        let from: (x: Double, y: Double)
        let to: (x: Double, y: Double)
        // A swipe on a small element (a column header, a chip) would move a few points and scroll nothing, so it spans the window along
        // the element's row or column. A wide element (a list row, for swipe-to-delete) is swiped within its own width.
        let horizontal = finger == .left || finger == .right
        let small = horizontal ? frame.width < width * 0.6 : frame.height < height * 0.4
        let acrossWindow = requested ?? small
        if acrossWindow {
            // A scroll needs real travel even when the container is small (a row of chips): span most of the window along the
            // element's row or column.
            switch finger {
            case .left: (from, to) = ((width * 0.85, center.y), (width * 0.15, center.y))
            case .right: (from, to) = ((width * 0.15, center.y), (width * 0.85, center.y))
            case .up: (from, to) = ((center.x, height * 0.7), (center.x, height * 0.3))
            case .down: (from, to) = ((center.x, height * 0.3), (center.x, height * 0.7))
            }
        } else {
            let dx = frame.width * 0.35, dy = frame.height * 0.35
            from = center
            switch finger {
            case .up: to = (center.x, center.y - dy)
            case .down: to = (center.x, center.y + dy)
            case .left: to = (center.x - dx, center.y)
            case .right: to = (center.x + dx, center.y)
            }
        }
        try await client.run(["ui", "swipe"], options: ["--duration", "0.4"],
                             positional: [Self.coordinate(from.x), Self.coordinate(from.y), Self.coordinate(to.x), Self.coordinate(to.y)])
        return await done("\(summary) \(Self.describe(target))")
    }

    private func done(_ summary: String) async -> ToolResult {
        try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "idb \(summary).")
    }

    /// idb reports a process ID as a number in the tree and as a string in the app list.
    private static func processID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func isInFront(_ app: (name: String, pid: Int?), name: String?, pid: Int?) -> Bool {
        if let name, !name.isEmpty, name == app.name { return true }
        if let pid, let known = app.pid, pid == known { return true }
        return false
    }

    /// An installed, running application's display name and process ID from `idb list-apps`.
    private func application(for bundleID: String, refresh: Bool) async throws -> (name: String, pid: Int?) {
        if !refresh, let known = applications[bundleID] { return known }
        let data = try await client.run(["list-apps"], options: ["--json"])
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  entry["bundle_id"] as? String == bundleID, let name = entry["name"] as? String else { continue }
            guard (entry["process_state"] as? String) == "Running" else {
                // The very first look at the app of a run: a case begins with "launch the application", so a stopped app is started
                // once. Later in a run a stopped app is a crash and stays an error.
                if latestSnapshot == nil, !launchedForRun.contains(bundleID) {
                    launchedForRun.insert(bundleID)
                    await client.launchApp(bundleID)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return try await application(for: bundleID, refresh: true)
                }
                throw DriverError.wrongApplication(expected: bundleID, observed: "not running", verdict: .notForeground)
            }
            let known = (name: name, pid: Self.processID(entry["pid"]))
            applications[bundleID] = known
            return known
        }
        throw DriverError.simulatorNotAvailable("\(bundleID) is not installed on \(udid)")
    }

    // MARK: - Remote-hosted content

    /// Content hosted in another process (the share sheet, other system sheets) reports frames relative to the sheet, not the
    /// screen. In the nested tree such content sits under a `RemoteElement` whose own frame starts at (0, 0); the sheet's real
    /// origin is its parent's. Read the nested tree once, learn each remote subtree's origin, and move those frames to screen
    /// coordinates, so a tap by frame lands where the element is.
    private func correctingRemoteFrames(_ nodes: [[String: Any]]) async -> [[String: Any]] {
        guard let data = try? await client.run(["ui", "describe-all"], options: ["--api", "axbridge", "--nested"]),
              let roots = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nodes }
        var offsets: [String: (dx: Double, dy: Double)] = [:]

        func key(_ node: [String: Any], _ frame: [String: Any]) -> String {
            func n(_ k: String) -> String { String(format: "%.1f", (frame[k] as? NSNumber)?.doubleValue ?? 0) }
            return "\(node["type"] as? String ?? "")|\(node["AXLabel"] as? String ?? "")|\(node["AXUniqueId"] as? String ?? "")|\(n("x")),\(n("y")),\(n("width")),\(n("height"))"
        }
        func walk(_ node: [String: Any], offset: (dx: Double, dy: Double), parentOrigin: (x: Double, y: Double)) {
            var childOffset = offset
            let frame = node["frame"] as? [String: Any] ?? [:]
            let localX = (frame["x"] as? NSNumber)?.doubleValue ?? 0, localY = (frame["y"] as? NSNumber)?.doubleValue ?? 0
            if (node["type"] as? String) == "RemoteElement" { childOffset = (parentOrigin.x, parentOrigin.y) }
            if !frame.isEmpty, childOffset.dx != 0 || childOffset.dy != 0 { offsets[key(node, frame)] = childOffset }
            let absoluteOrigin = (x: localX + (node["type"] as? String == "RemoteElement" ? childOffset.dx : offset.dx),
                                  y: localY + (node["type"] as? String == "RemoteElement" ? childOffset.dy : offset.dy))
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child, offset: childOffset, parentOrigin: absoluteOrigin) }
        }
        for root in roots { walk(root, offset: (0, 0), parentOrigin: (0, 0)) }
        guard !offsets.isEmpty else { return nodes }
        return nodes.map { node in
            guard var frame = node["frame"] as? [String: Any], let shift = offsets[key(node, frame)] else { return node }
            frame["x"] = ((frame["x"] as? NSNumber)?.doubleValue ?? 0) + shift.dx
            frame["y"] = ((frame["y"] as? NSNumber)?.doubleValue ?? 0) + shift.dy
            var corrected = node
            corrected["frame"] = frame
            return corrected
        }
    }

    // MARK: - Mapping

    private static func center(of element: UIElementSnapshot) throws -> (x: Double, y: Double) {
        guard let frame = element.frame, frame.width > 0, frame.height > 0 else { throw DriverError.elementNotHittable(element.id) }
        return (frame.x + frame.width / 2, frame.y + frame.height / 2)
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }

    /// idb accepts whole-number point coordinates only.
    private static func coordinate(_ value: Double) -> String { String(Int(value.rounded())) }

    private static func describe(_ element: UIElementSnapshot) -> String {
        "'\(element.identifier ?? element.label ?? element.id)' (\(element.role))"
    }
}

private extension ScrollDirection {
    var opposite: ScrollDirection {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }
}

/// The last error an observation read hit, kept so the final "no tree" error can say why.
private final class FailureNote: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return text }
}
