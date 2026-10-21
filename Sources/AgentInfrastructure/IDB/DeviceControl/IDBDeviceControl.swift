import Foundation
import AgentCore

/// The device-control lane over idb: validates a command, turns it into idb or simctl calls, runs them through `IDBClient` (the only place a
/// process is started), and returns text an agent can read. It is separate from the case runner's driver: it never touches the trusted spine.
public actor IDBDeviceControl: DeviceControlling {
    private let executable: URL
    private let preferredUDID: String
    /// Longest result handed back, so a log or a tree cannot flood an agent's context.
    static let maxResultCharacters = 6000
    static let maxScreenElements = 120

    /// The last full digest per target, and the numbers given out: `read_screen` after an action can then say only what changed, and `#4` keeps its meaning.
    private var lastDigest: [String: ScreenDigest] = [:]
    private var books: [String: HandleBook] = [:]
    private var digestVersion = 0

    /// Answers questions about a screenshot; nil without a Gemini key, in which case `look` says so.
    private let questioner: (any ScreenQuestioning)?
    private var lookAnswers: [String: String] = [:]

    /// Where the booted simulators come from; `simctl` unless a test replaces it.
    private let bootedSimulators: (@Sendable () async -> [DeviceTarget])?

    init(executable: URL, preferredUDID: String, questioner: (any ScreenQuestioning)? = nil, bootedSimulators: (@Sendable () async -> [DeviceTarget])? = nil) {
        self.executable = executable
        self.preferredUDID = preferredUDID
        self.questioner = questioner
        self.bootedSimulators = bootedSimulators
    }

    // MARK: DeviceControlling

    public func targets() async throws -> [DeviceTarget] {
        let client = IDBClient(executable: executable, udid: preferredUDID)
        return Self.parseTargets(try await client.runGlobal(["list-targets"], options: ["--json"]))
    }

    /// The booted simulator (the preferred one when several are). `simctl` answers in a fraction of a second; idb's own listing walks every simulator and
    /// takes seconds, so it is only the fallback. This sits on the path of every first command, so its speed is every command's speed.
    public func defaultTarget() async -> DeviceTarget? {
        var booted: [DeviceTarget] = []
        if let bootedSimulators { booted = await bootedSimulators() }
        else if let data = try? await IDBClient(executable: executable, udid: preferredUDID, timeLimit: 15).runSimctl(["list", "devices", "booted", "-j"]) {
            booted = Self.parseBootedSimulators(data)
        }
        if booted.isEmpty, let all = try? await targets() { booted = all.filter { $0.kind == .simulator && $0.isBooted } }
        return booted.first { $0.udid == preferredUDID } ?? booted.first
    }

    public func run(_ command: DeviceCommand, on target: DeviceTarget, context: DeviceValidationContext) async throws -> DeviceCommandResult {
        let command = try DeviceCommandValidator.validate(command, context: context)
        let spec = DeviceCommandCatalog.spec(for: command.kind)
        if spec.support == .simulatorOnly, target.kind != .simulator {
            throw DeviceControlError.unsupportedOnTarget("\(command.kind.rawValue) works on simulators only; \(target.name) is a \(target.kind.rawValue).")
        }
        let client = IDBClient(executable: executable, udid: target.udid, timeLimit: command.kind == .installApp ? 120 : 30)
        do {
            switch command.kind {
            case .listTargets: return try await listTargets(command, client: client)
            case .describeScreen: return try await describeScreen(command, client: client)
            case .readScreen: return try await readScreenDigest(command, target: target, client: client)
            case .find: return try await find(command, target: target, client: client)
            case .waitFor: return try await waitFor(command, target: target, client: client)
            case .readElement: return try await readElement(command, target: target, client: client)
            case .scrollTo: return try await scrollTo(command, target: target, client: client)
            case .look: return try await look(command, client: client)
            case .tap, .doubleTap, .longPress: return try await tapLike(command, target: target, client: client)
            case .scroll: return try await scroll(command, target: target, client: client)
            case .listApps: return DeviceCommandResult(text: Self.cap(Self.summarizeApps(try await client.run(["list-apps"], options: ["--json"]), filter: command.string("filter"))))
            case .screenshot: return try await screenshot(command, target: target, client: client, context: context)
            case .filePull: return try await pull(command, target: target, client: client, context: context)
            default: return try await perform(command, target: target, client: client)
            }
        } catch let error as DeviceControlError {
            throw error
        } catch let error as IDBCommandBuilder.BuildError {
            throw DeviceControlError.invalid("\(command.kind.rawValue): \(error)")
        } catch {
            throw DeviceControlError.failed(SecretRedactor.redact(error.localizedDescription))
        }
    }

    // MARK: Running

    private static let changesTheScreen: Set<DeviceCommandKind> = [.launchApp, .openURL, .terminateApp]

    /// The plain case: build the calls, run them in order, return what the last one printed (or a confirmation).
    private func perform(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient, outputPath: String? = nil) async throws -> DeviceCommandResult {
        var output = Data()
        for invocation in try IDBCommandBuilder.invocations(for: command, udid: target.udid, outputPath: outputPath) {
            switch invocation {
            case .idb(let words, let options, let positional): output = try await client.run(words, options: options, positional: positional)
            case .idbGlobal(let words, let options): output = try await client.runGlobal(words, options: options)
            case .simctl(let arguments): output = try await client.runSimctl(arguments)
            }
        }
        var text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Appearance is not always visible on screen (a web page stays light), so the result reads it back: that is the evidence a check can use.
        if command.kind == .setAppearance {
            let now = String(decoding: (try? await client.runSimctl(["ui", target.udid, "appearance"])) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !now.isEmpty { return DeviceCommandResult(text: "The device appearance is now \(now).") }
        }
        if command.kind == .readLog { text = Self.lastLines(text, command.integer("lines") ?? 80) }
        // The screen takes a moment to change after these (the home animation, an app coming forward): wait, so the next read sees the new screen.
        if Self.changesTheScreen.contains(command.kind) || (command.kind == .pressButton && command.string("button") == "HOME") { try? await Task.sleep(nanoseconds: 700_000_000) }
        let done = DeviceCommandCatalog.phrase(command)
        return DeviceCommandResult(text: Self.cap(text.isEmpty ? "Done: \(done)." : text))
    }

    private func listTargets(_ command: DeviceCommand, client: IDBClient) async throws -> DeviceCommandResult {
        let output = try await client.runGlobal(["list-targets"], options: ["--json"] + (command.string("only").map { ["--only", $0] } ?? []))
        let all = Self.parseTargets(output)
        guard !all.isEmpty else { return DeviceCommandResult(text: "No simulators or devices found.") }
        let lines = all.map { "\($0.name) (\($0.kind.rawValue), \($0.osVersion), \($0.state.lowercased())) \($0.udid)" }
        return DeviceCommandResult(text: Self.cap(lines.joined(separator: "\n")))
    }

    // MARK: Looking at the screen

    private func readScreen(_ client: IDBClient) async throws -> (elements: [UIElementSnapshot], window: ElementFrame?) {
        guard let nodes = IDBAccessibilityTree.nodes(from: try await client.run(["ui", "describe-all"])), !nodes.isEmpty else {
            throw DeviceControlError.failed("The device returned no accessibility tree. Is an app on screen?")
        }
        let window = IDBAccessibilityTree.frame(of: nodes[0])
        return (nodes.enumerated().map { IDBAccessibilityTree.element(from: $1, index: $0, window: window) }, window)
    }

    private func describeScreen(_ command: DeviceCommand, client: IDBClient) async throws -> DeviceCommandResult {
        let (elements, window) = try await readScreen(client)
        let onlyActive = command.string("filter") == "interactable"
        let shown = elements.dropFirst().filter { element in
            let named = !(element.label ?? "").isEmpty || !(element.identifier ?? "").isEmpty || !(element.value ?? "").isEmpty
            return named && (!onlyActive || element.isHittable)
        }
        let lines = shown.prefix(Self.maxScreenElements).map { Self.describe($0) }
        var text = "Screen \(window.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?") points, \(shown.count) named element(s)"
        if shown.count > Self.maxScreenElements { text += " (first \(Self.maxScreenElements) shown)" }
        return DeviceCommandResult(text: Self.cap(text + ":\n" + lines.joined(separator: "\n")))
    }

    private func buildDigest(_ elements: [UIElementSnapshot], _ window: ElementFrame?, udid: String, limit: Int, reset: Bool) -> ScreenDigest {
        digestVersion += 1
        var book = reset ? HandleBook() : (books[udid] ?? HandleBook())
        let digest = ScreenDigestBuilder.build(elements: elements, window: window, version: digestVersion, limit: limit, handles: &book)
        books[udid] = book
        return digest
    }

    /// The screen in a few lines; after the first read, only what changed. A different screen starts the numbers again.
    private func readScreenDigest(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient) async throws -> DeviceCommandResult {
        var (elements, window) = try await readScreen(client)
        // Right after a transition (the home screen coming back, an app launching) the tree can be empty for a moment: look once more before saying so.
        if window == nil || window?.width == 0 { try? await Task.sleep(nanoseconds: 900_000_000); (elements, window) = try await readScreen(client) }
        let mode = command.string("mode") ?? "auto"
        let query = command.string("query")
        var digest = buildDigest(elements, window, udid: target.udid, limit: command.integer("limit") ?? ScreenDigestBuilder.defaultLimit, reset: false)
        var text: String
        if query == nil, mode != "full", let previous = lastDigest[target.udid], let changes = ScreenDigestBuilder.diff(from: previous, to: digest) {
            // `state` returns both, for an agent that needs the whole screen and also what just changed.
            text = mode == "state" ? changes + "\n---\n" + ScreenDigestBuilder.render(digest) : changes
        } else {
            if let previous = lastDigest[target.udid], ScreenDigestBuilder.diff(from: previous, to: digest) == nil {
                digest = buildDigest(elements, window, udid: target.udid, limit: command.integer("limit") ?? ScreenDigestBuilder.defaultLimit, reset: true)
            }
            text = ScreenDigestBuilder.render(digest, query: query)
        }
        if query == nil { lastDigest[target.udid] = digest }
        return DeviceCommandResult(text: Self.cap(text))
    }

    /// The screenshot, shrunk, sent to the vision model with the question; the answer comes back as text. The same screen and question are answered once.
    private func look(_ command: DeviceCommand, client: IDBClient) async throws -> DeviceCommandResult {
        guard let questioner else {
            return DeviceCommandResult(ok: false, text: "Looking at the screen needs a Gemini key (GEMINI_API_KEY). Use read_screen or find instead.")
        }
        let question = command.string("question") ?? ""
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("look-\(UUID().uuidString.prefix(8)).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await client.screenshot(to: path)
        guard let png = FileManager.default.contents(atPath: path) else { throw DeviceControlError.failed("The screenshot could not be read.") }
        let small = ScreenshotCompressor.jpeg(from: png, maxPixels: 700, quality: 0.6)
        let image = small ?? png
        let key = "\(Self.fingerprint(image))|\(question)"
        if let known = lookAnswers[key] { return DeviceCommandResult(text: known) }
        let answer = try await questioner.answer(question: question, screenshot: image, mimeType: small == nil ? "image/png" : "image/jpeg")
        let text = Self.cap(String(answer.prefix(900)))
        if lookAnswers.count > 20 { lookAnswers.removeAll() }
        lookAnswers[key] = text
        return DeviceCommandResult(text: text)
    }

    private static func fingerprint(_ data: Data) -> String {
        // The whole image (FNV-1a): a prefix hash treated two screens that differ only further down as the same one.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "\(data.count)-\(hash)"
    }

    private func find(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient) async throws -> DeviceCommandResult {
        let (elements, window) = try await readScreen(client)
        let digest = buildDigest(elements, window, udid: target.udid, limit: 400, reset: false)
        let needle = (command.string("text") ?? "").lowercased()
        let role = command.string("role")?.lowercased()
        let matches = (digest.controls + digest.texts).filter { item in
            [item.label, item.identifier ?? "", item.value ?? ""].contains { $0.lowercased().contains(needle) } && (role == nil || item.role.lowercased().contains(role ?? ""))
        }
        guard !matches.isEmpty else { return DeviceCommandResult(text: "Nothing on screen matches “\(command.string("text") ?? "")”. It may be further down: scroll, then read_screen.") }
        return DeviceCommandResult(text: Self.cap(matches.prefix(25).map { ScreenDigestBuilder.line($0) }.joined(separator: "\n")))
    }

    /// One element's state, from a fresh read: what a check of a toggle, a field or a selection needs.
    private func readElement(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient) async throws -> DeviceCommandResult {
        let (elements, _) = try await readScreen(client)
        var lookup = command
        if let handle = command.string("handle") {
            guard let number = Int(handle.hasPrefix("#") ? String(handle.dropFirst()) : handle), let known = (lastDigest[target.udid].map { $0.controls + $0.texts } ?? []).first(where: { $0.handle == number }) else {
                throw DeviceControlError.failed("There is no element \(handle) yet. Use read_screen first.")
            }
            lookup = DeviceCommand(.readElement, known.identifier.map { $0.isEmpty ? ["label": .string(known.label)] : ["identifier": .string($0)] } ?? ["label": .string(known.label)])
        }
        let element = try Self.uniqueElement(for: lookup, in: elements)
        var parts = ["\(element.role) “\(Self.name(of: element))”"]
        if let identifier = element.identifier, !identifier.isEmpty { parts.append("id=\(identifier)") }
        parts.append("value=" + (element.value.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? "none"))
        parts.append(element.isEnabled ? "enabled" : "disabled")
        parts.append(element.isSelected == true ? "selected" : "not selected")
        parts.append(element.isHittable ? "on screen" : "off screen")
        if ToggleCheck.isToggle(element) { parts.append("a switch is ON when its value is 1 or on") }
        return DeviceCommandResult(text: parts.joined(separator: ", "))
    }

    /// Scrolls a step at a time and looks, so the caller makes one call instead of scroll, read, scroll, read.
    private func scrollTo(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient) async throws -> DeviceCommandResult {
        let text = command.string("text") ?? ""
        let limit = min(max(command.integer("max_scrolls") ?? 8, 1), 20)
        let lookup = DeviceCommand(.find, ["text": .string(text)])
        var stepArguments: [String: DeviceValue] = ["direction": .string(command.string("direction") ?? "down")]
        if let within = command.string("within") { stepArguments["within"] = .string(within) }
        let step = DeviceCommand(.scroll, stepArguments)
        for done in 0...limit {
            let found = try await find(lookup, target: target, client: client)
            if !found.text.hasPrefix("Nothing on screen matches"), found.text.contains("off-screen") == false {
                return DeviceCommandResult(text: "“\(text)” is on screen after \(done) scroll\(done == 1 ? "" : "s").\n" + found.text)
            }
            if done == limit { break }
            _ = try await scroll(step, target: target, client: client)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return DeviceCommandResult(ok: false, text: "“\(text)” did not come into view after \(limit) scrolls \(command.string("direction") ?? "down"). It may not exist on this screen, or it is in another direction.")
    }

    /// Polls the screen until the text is on it (or gone), so the caller makes one call instead of many. Returns what `find` found, or fails with the screen as it is.
    private func waitFor(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient) async throws -> DeviceCommandResult {
        let text = command.string("text") ?? ""
        let disappears = command.string("until") == "disappears"
        let timeout = min(max(command.number("timeout") ?? 10, 1), 60)
        let started = Date()
        let lookup = DeviceCommand(.find, ["text": .string(text)])
        while true {
            let found = try await find(lookup, target: target, client: client)
            let present = !found.text.hasPrefix("Nothing on screen matches")
            let waited = Date().timeIntervalSince(started)
            if present != disappears { return DeviceCommandResult(text: String(format: "“%@” %@ after %.1f s.", text, disappears ? "is gone" : "is on screen", waited) + (disappears ? "" : "\n" + found.text)) }
            if waited >= timeout {
                let screen = try await readScreenDigest(DeviceCommand(.readScreen, ["limit": .number(25)]), target: target, client: client)
                return DeviceCommandResult(ok: false, text: String(format: "“%@” %@ after %.0f s. The screen now:\n", text, disappears ? "was still there" : "did not appear", timeout) + screen.text)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    /// Taps by #number from the last read_screen (checked against a fresh read: the element must still be there), by label or identifier (exactly
    /// one element must match), or at a point.
    private func tapLike(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient) async throws -> DeviceCommandResult {
        var resolved = command
        var what = DeviceCommandCatalog.phrase(command)
        var toggle: UIElementSnapshot?   // a switch or checkbox being tapped: read again afterwards to see that it changed
        if let handle = command.string("handle") {
            guard let number = Int(handle.hasPrefix("#") ? String(handle.dropFirst()) : handle) else { throw DeviceControlError.invalid("“handle” must look like #4.") }
            guard let previous = lastDigest[target.udid], let known = (previous.controls + previous.texts).first(where: { $0.handle == number }) else {
                throw DeviceControlError.failed("There is no element #\(number) yet. Use read_screen first, then tap by its number.")
            }
            let (elements, window) = try await readScreen(client)
            let fresh = buildDigest(elements, window, udid: target.udid, limit: 400, reset: false)
            guard let current = (fresh.controls + fresh.texts).first(where: { $0.handle == number }) else {
                throw DeviceControlError.failed("#\(number) “\(known.label)” is no longer on screen. Use read_screen to see the screen now.")
            }
            resolved.arguments["x"] = .number(Double(current.x))
            resolved.arguments["y"] = .number(Double(current.y))
            toggle = elements.first { element in
                guard ToggleCheck.isToggle(element), let f = element.frame else { return false }
                return abs(f.x + f.width / 2 - Double(current.x)) < 2 && abs(f.y + f.height / 2 - Double(current.y)) < 2
            }
            what = "\(command.kind == .tap ? "Tapped" : command.kind == .doubleTap ? "Double-tapped" : "Pressed and held") #\(number) “\(current.label)” at (\(current.x), \(current.y))"
        } else if command.number("x") == nil || command.number("y") == nil {
            let (elements, _) = try await readScreen(client)
            let element = try Self.uniqueElement(for: command, in: elements)
            if ToggleCheck.isToggle(element) { toggle = element }
            guard let frame = element.frame else { throw DeviceControlError.failed("“\(Self.name(of: element))” has no position on screen.") }
            resolved.arguments["x"] = .number((frame.x + frame.width / 2).rounded())
            resolved.arguments["y"] = .number((frame.y + frame.height / 2).rounded())
            what = "\(command.kind == .tap ? "Tapped" : command.kind == .doubleTap ? "Double-tapped" : "Pressed and held") “\(Self.name(of: element))” at (\(Int(frame.x + frame.width / 2)), \(Int(frame.y + frame.height / 2)))"
        }
        let result = try await perform(resolved, target: target, client: client)
        if command.kind == .tap, let toggle {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let (after, _) = try? await readScreen(client), let reason = ToggleCheck.unchanged(before: toggle, after: after) {
                return DeviceCommandResult(ok: false, text: what + ", but it did not toggle: " + reason + ". Tap its switch, not its label.", pointX: resolved.number("x"), pointY: resolved.number("y"))
            }
        }
        return DeviceCommandResult(text: what.hasPrefix("Tap") || what.hasPrefix("Double") || what.hasPrefix("Press") ? what + "." : result.text,
                                   pointX: resolved.number("x"), pointY: resolved.number("y"))
    }

    /// A scroll is a swipe across the middle of the screen; the finger moves opposite to the content.
    private func scroll(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient) async throws -> DeviceCommandResult {
        let (elements, window) = try await readScreen(client)
        let width = window?.width ?? 402, height = window?.height ?? 874
        let x = window?.x ?? 0, y = window?.y ?? 0
        var cx = x + width / 2, cy = y + height / 2
        // A row that scrolls by itself (chips, tabs) is swiped along its own line, not through the middle of the screen.
        if let within = command.string("within"), !within.isEmpty {
            let anchor = try Self.uniqueElement(for: DeviceCommand(.find, ["label": .string(within)]), in: elements)
            if let frame = anchor.frame { cx = frame.x + frame.width / 2; cy = frame.y + frame.height / 2 }
        }
        let direction = command.string("direction") ?? "down"
        let (from, to): ((Double, Double), (Double, Double))
        switch direction {
        case "down": (from, to) = ((cx, y + height * 0.7), (cx, y + height * 0.3))
        case "up": (from, to) = ((cx, y + height * 0.3), (cx, y + height * 0.7))
        case "left": (from, to) = ((x + width * 0.15, cy), (x + width * 0.85, cy))
        default: (from, to) = ((x + width * 0.85, cy), (x + width * 0.15, cy))
        }
        func number(_ value: Double) -> DeviceValue { .number(value.rounded()) }
        let swipe = DeviceCommand(.swipe, ["x1": number(from.0), "y1": number(from.1), "x2": number(to.0), "y2": number(to.1), "seconds": .number(0.4)])
        _ = try await perform(swipe, target: target, client: client)
        return DeviceCommandResult(text: "Scrolled \(direction).")
    }

    private func screenshot(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient, context: DeviceValidationContext) async throws -> DeviceCommandResult {
        try FileManager.default.createDirectory(at: context.outputDirectory, withIntermediateDirectories: true)
        let path = context.outputDirectory.appendingPathComponent("screenshot-\(Self.timestamp()).png").path
        _ = try await perform(command, target: target, client: client, outputPath: path)
        return DeviceCommandResult(text: "Screenshot saved to \(path)", filePath: path)
    }

    private func pull(_ command: DeviceCommand, target: DeviceTarget, client: IDBClient, context: DeviceValidationContext) async throws -> DeviceCommandResult {
        let folder = context.outputDirectory.appendingPathComponent("pull-\(Self.timestamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await perform(command, target: target, client: client, outputPath: folder.path)
        return DeviceCommandResult(text: "Copied to \(folder.path)", filePath: folder.path)
    }

    // MARK: Reading output (pure, tested)

    /// The booted simulators from `simctl list devices booted -j` (`{"devices": {"<runtime>": [{udid, name, state}]}}`).
    static func parseBootedSimulators(_ data: Data) -> [DeviceTarget] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let groups = root["devices"] as? [String: Any] else { return [] }
        var found: [DeviceTarget] = []
        for (runtime, list) in groups.sorted(by: { $0.key < $1.key }) {
            // "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5"
            let tail = runtime.components(separatedBy: ".").last ?? runtime
            let parts = tail.components(separatedBy: "-")
            let os = parts.count > 1 ? parts[0] + " " + parts.dropFirst().joined(separator: ".") : tail
            for case let device as [String: Any] in (list as? [Any]) ?? [] {
                guard let udid = device["udid"] as? String, (device["state"] as? String) == "Booted" else { continue }
                found.append(DeviceTarget(udid: udid, name: device["name"] as? String ?? udid, kind: .simulator, state: "Booted", osVersion: os))
            }
        }
        return found
    }

    static func parseTargets(_ data: Data) -> [DeviceTarget] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let udid = object["udid"] as? String else { return nil }
            let kind = DeviceTarget.Kind(rawValue: (object["type"] as? String ?? "").lowercased()) ?? .device
            return DeviceTarget(udid: udid, name: object["name"] as? String ?? udid, kind: kind, state: object["state"] as? String ?? "Unknown", osVersion: object["os_version"] as? String ?? "")
        }
    }

    static func summarizeApps(_ data: Data, filter: String? = nil) -> String {
        let apps = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let bundle = object["bundle_id"] as? String else { return nil }
            let running = (object["process_state"] as? String) == "Running" ? " [running]" : ""
            return "\(bundle)  \(object["name"] as? String ?? "")\(running)"
        }
        let kept = filter.map { needle in apps.filter { $0.localizedCaseInsensitiveContains(needle) } } ?? apps
        return kept.isEmpty ? (filter == nil ? "No apps found." : "No app matches “\(filter ?? "")”.") : kept.sorted().joined(separator: "\n")
    }

    static func name(of element: UIElementSnapshot) -> String {
        [element.label, element.identifier, element.value].compactMap { $0 }.first { !$0.isEmpty } ?? element.role
    }

    static func describe(_ element: UIElementSnapshot) -> String {
        var parts = ["\(element.role) “\(name(of: element))”"]
        if let identifier = element.identifier, !identifier.isEmpty, identifier != name(of: element) { parts.append("id=\(identifier)") }
        if let value = element.value, !value.isEmpty, value != name(of: element) { parts.append("value=\(value.prefix(60))") }
        if let frame = element.frame { parts.append("at (\(Int(frame.x + frame.width / 2)), \(Int(frame.y + frame.height / 2))) \(Int(frame.width))x\(Int(frame.height))") }
        if !element.isHittable { parts.append("off-screen") }
        if !element.isEnabled { parts.append("disabled") }
        return parts.joined(separator: " ")
    }

    /// The one element a label or identifier names. Several matches are not guessed between: the candidates come back so the caller can choose.
    static func uniqueElement(for command: DeviceCommand, in elements: [UIElementSnapshot]) throws -> UIElementSnapshot {
        let wanted = command.string("identifier") ?? command.string("label") ?? ""
        let byIdentifier = command.string("identifier") != nil
        func matches(_ element: UIElementSnapshot, exact: Bool) -> Bool {
            let candidates = byIdentifier ? [element.identifier] : [element.label, element.identifier, element.value]
            return candidates.compactMap { $0 }.contains { exact ? $0.caseInsensitiveCompare(wanted) == .orderedSame : $0.localizedCaseInsensitiveContains(wanted) }
        }
        var found = elements.filter { matches($0, exact: true) }
        if found.isEmpty { found = elements.filter { matches($0, exact: false) } }
        // An element that is not on screen cannot be tapped where it is; prefer one that is.
        let onScreen = found.filter(\.isHittable)
        if !onScreen.isEmpty { found = onScreen }
        switch found.count {
        case 1: return found[0]
        case 0: throw DeviceControlError.failed("Nothing on screen is called “\(wanted)”. Use describe_screen to see what is there.")
        default:
            let list = found.prefix(8).map { "  - \(describe($0))" }.joined(separator: "\n")
            throw DeviceControlError.failed("“\(wanted)” matches \(found.count) elements; tap one by position (x, y) or use a more specific label:\n\(list)")
        }
    }

    static func lastLines(_ text: String, _ count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(max(1, count)).joined(separator: "\n")
    }

    static func cap(_ text: String) -> String {
        let clean = SecretRedactor.redact(text)
        return clean.count > maxResultCharacters ? String(clean.prefix(maxResultCharacters)) + "\n…(\(clean.count - maxResultCharacters) more characters)" : clean
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
