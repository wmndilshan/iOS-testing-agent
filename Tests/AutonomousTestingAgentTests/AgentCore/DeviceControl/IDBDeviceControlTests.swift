import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// A stand-in for `idb`: records every call in a log file, prints a fixed accessibility tree, app list and target list, and accepts the rest.
private struct FakeIDB {
    let executable: URL
    let log: URL

    init(tree: String) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fake-idb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appendingPathComponent("calls.log")
        executable = directory.appendingPathComponent("idb")
        try """
        #!/bin/sh
        echo "$@" >> "\(log.path)"
        if [ "$1" = "ui" ] && [ "$2" = "describe-all" ]; then
        cat <<'JSON'
        \(tree)
        JSON
        fi
        if [ "$1" = "screenshot" ]; then
        for last; do :; done
        echo 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d > "$last"
        fi
        if [ "$1" = "list-apps" ]; then
        echo '{"bundle_id": "com.apple.mobilesafari", "name": "Safari", "process_state": "Running"}'
        echo '{"bundle_id": "com.example.app", "name": "Example", "process_state": "Not Running"}'
        fi
        if [ "$1" = "list-targets" ]; then
        echo '{"name": "iPhone 17 Pro", "udid": "SIM-1", "state": "Booted", "type": "simulator", "os_version": "iOS 26.5"}'
        echo '{"name": "Bob\\u2019s iPhone", "udid": "DEV-1", "state": "Booted", "type": "device", "os_version": "iOS 26.0"}'
        fi
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
}

private func node(_ type: String, label: String? = nil, id: String? = nil, x: Int, y: Int, w: Int, h: Int) -> String {
    let labelField = label.map { ", \"AXLabel\": \"\($0)\"" } ?? ""
    let idField = id.map { ", \"AXUniqueId\": \"\($0)\"" } ?? ""
    return "{\"type\": \"\(type)\", \"enabled\": true, \"frame\": {\"x\": \(x), \"y\": \(y), \"width\": \(w), \"height\": \(h)}\(labelField)\(idField)}"
}

private let simulator = DeviceTarget(udid: "SIM-1", name: "iPhone 17 Pro", kind: .simulator, state: "Booted", osVersion: "iOS 26.5")
private let phone = DeviceTarget(udid: "DEV-1", name: "Bob's iPhone", kind: .device, state: "Booted", osVersion: "iOS 26.0")

@Suite("idb device control")
struct IDBDeviceControlTests {
    private func control(_ nodes: [String]) throws -> (IDBDeviceControl, FakeIDB, DeviceValidationContext) {
        let fake = try FakeIDB(tree: "[" + nodes.joined(separator: ",\n") + "]")
        let root = ProductFixtures.tempDir()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (IDBDeviceControl(executable: fake.executable, preferredUDID: "SIM-1", bootedSimulators: { [] }), fake, DeviceValidationContext(projectRoot: root, repository: nil))
    }

    private let screen = [node("Application", label: "Demo", x: 0, y: 0, w: 402, h: 874),
                          node("Button", label: "Settings", id: "open-settings", x: 100, y: 200, w: 80, h: 44),
                          node("Button", label: "Save", x: 10, y: 300, w: 60, h: 40), node("Button", label: "Save", x: 10, y: 400, w: 60, h: 40),
                          node("Button", label: "Orders", x: 20, y: 500, w: 100, h: 50)]

    @Test("wait_for returns at once when the text is there, and fails with the screen when it never appears or never goes")
    func waitFor() async throws {
        let (device, _, context) = try control(screen)
        let here = try await device.run(DeviceCommand(.waitFor, ["text": .string("Orders")]), on: simulator, context: context)
        #expect(here.ok && here.text.hasPrefix("“Orders” is on screen after") && here.text.contains("Orders"))
        let missing = try await device.run(DeviceCommand(.waitFor, ["text": .string("Checkout"), "timeout": .number(1)]), on: simulator, context: context)
        #expect(!missing.ok && missing.text.contains("did not appear after 1 s") && missing.text.contains("The screen now:") && missing.text.contains("Orders"))
        let stays = try await device.run(DeviceCommand(.waitFor, ["text": .string("Orders"), "until": .string("disappears"), "timeout": .number(1)]), on: simulator, context: context)
        #expect(!stays.ok && stays.text.contains("was still there"))
        let gone = try await device.run(DeviceCommand(.waitFor, ["text": .string("Checkout"), "until": .string("disappears")]), on: simulator, context: context)
        #expect(gone.ok && gone.text.contains("is gone"))
        #expect(DeviceCommandCatalog.phrase(DeviceCommand(.waitFor, ["text": .string("Done")])) == "Wait for “Done” to appear")
        #expect(DeviceCommandCatalog.spec(for: .waitFor).risk == .readOnly)
    }

    @Test("describe_screen lists named elements with their centres, and counts them")
    func describe() async throws {
        let (device, _, context) = try control(screen)
        let result = try await device.run(DeviceCommand(.describeScreen), on: simulator, context: context)
        #expect(result.text.contains("Screen 402x874 points, 4 named element(s)"))
        #expect(result.text.contains("button “Settings” id=open-settings at (140, 222) 80x44"))
    }

    @Test("tap by label finds the one element and taps its centre")
    func tapByLabel() async throws {
        let (device, fake, context) = try control(screen)
        let result = try await device.run(DeviceCommand(.tap, ["label": .string("settings")]), on: simulator, context: context)
        #expect(result.text == "Tapped “Settings” at (140, 222).")
        #expect(fake.calls.contains("ui tap --udid SIM-1 140 222"))
    }

    @Test("tap by identifier works; tap by point goes straight through without reading the screen")
    func tapOthers() async throws {
        let (device, fake, context) = try control(screen)
        _ = try await device.run(DeviceCommand(.tap, ["identifier": .string("open-settings")]), on: simulator, context: context)
        #expect(fake.calls.contains("ui tap --udid SIM-1 140 222"))
        _ = try await device.run(DeviceCommand(.tap, ["x": .number(5), "y": .number(6)]), on: simulator, context: context)
        #expect(fake.calls.last == "ui tap --udid SIM-1 5 6")
        #expect(fake.calls.filter { $0.hasPrefix("ui describe-all") }.count == 1)
    }

    @Test("A label that matches several elements is not guessed: the candidates come back and nothing is tapped")
    func ambiguous() async throws {
        let (device, fake, context) = try control(screen)
        await #expect(throws: DeviceControlError.self) { _ = try await device.run(DeviceCommand(.tap, ["label": .string("Save")]), on: simulator, context: context) }
        do { _ = try await device.run(DeviceCommand(.tap, ["label": .string("Save")]), on: simulator, context: context) }
        catch { #expect(error.localizedDescription.contains("matches 2 elements") && error.localizedDescription.contains("(40, 320)")) }
        #expect(!fake.calls.contains { $0.hasPrefix("ui tap") })
    }

    @Test("A label that is not on screen says so and points to describe_screen")
    func missing() async throws {
        let (device, _, context) = try control(screen)
        do { _ = try await device.run(DeviceCommand(.tap, ["label": .string("Nope")]), on: simulator, context: context) }
        catch { #expect(error.localizedDescription.contains("Nothing on screen is called “Nope”") && error.localizedDescription.contains("describe_screen")) }
    }

    @Test("scroll becomes a swipe across the middle of the screen, finger moving opposite to the content")
    func scroll() async throws {
        let (device, fake, context) = try control(screen)
        let result = try await device.run(DeviceCommand(.scroll, ["direction": .string("down")]), on: simulator, context: context)
        #expect(result.text == "Scrolled down.")
        #expect(fake.calls.contains("ui swipe --udid SIM-1 --duration 0.4 201 612 201 262"))
    }

    @Test("Targets and apps are read as lists; a device is listed with its kind")
    func lists() async throws {
        let (device, _, context) = try control(screen)
        let targets = try await device.run(DeviceCommand(.listTargets), on: simulator, context: context)
        #expect(targets.text.contains("iPhone 17 Pro (simulator, iOS 26.5, booted) SIM-1") && targets.text.contains("(device, iOS 26.0, booted) DEV-1"))
        let apps = try await device.run(DeviceCommand(.listApps), on: simulator, context: context)
        #expect(apps.text == "com.apple.mobilesafari  Safari [running]\ncom.example.app  Example")
        #expect(try await device.defaultTarget()?.udid == "SIM-1")
    }

    @Test("A simulator-only command is refused on a real device, before anything is sent")
    func simulatorOnly() async throws {
        let (device, fake, context) = try control(screen)
        await #expect(throws: DeviceControlError.unsupportedOnTarget("set_location works on simulators only; Bob's iPhone is a device.")) {
            _ = try await device.run(DeviceCommand(.setLocation, ["latitude": .number(1), "longitude": .number(2)]), on: phone, context: context)
        }
        #expect(fake.calls.isEmpty)
        _ = try await device.run(DeviceCommand(.pressButton, ["button": .string("HOME")]), on: phone, context: context)
        #expect(fake.calls.last == "ui button --udid DEV-1 HOME")
    }

    @Test("A command is validated again here, whatever the caller did")
    func revalidates() async throws {
        let (device, fake, context) = try control(screen)
        await #expect(throws: DeviceControlError.self) { _ = try await device.run(DeviceCommand(.openURL, ["url": .string("file:///etc/passwd")]), on: simulator, context: context) }
        #expect(fake.calls.isEmpty)
    }

    @Test("A screenshot is saved under .runs/device and its path returned")
    func screenshot() async throws {
        let (device, fake, context) = try control(screen)
        let result = try await device.run(DeviceCommand(.screenshot), on: simulator, context: context)
        let path = try #require(result.filePath)
        #expect(path.hasPrefix(context.outputDirectory.path) && path.hasSuffix(".png"))
        #expect(fake.calls.contains { $0.hasPrefix("screenshot --udid SIM-1") && $0.hasSuffix(path) })
    }

    @Test("Results are capped and redacted")
    func capped() {
        let long = String(repeating: "x", count: IDBDeviceControl.maxResultCharacters + 500)
        #expect(IDBDeviceControl.cap(long).count < long.count && IDBDeviceControl.cap(long).contains("more characters"))
        #expect(IDBDeviceControl.lastLines("a\nb\nc\nd", 2) == "c\nd")
    }
}

@Suite("idb companion recovery")
struct IDBCompanionRecoveryTests {
    @Test("A process's own arguments can be read")
    func arguments() {
        let own = IDBRecovery.arguments(of: getpid())
        #expect(!own.isEmpty && own.contains { $0.contains("xctest") || $0.contains("swiftpm-testing-helper") || $0.contains("PackageTests") })
        #expect(IDBRecovery.arguments(of: 99_999_999).isEmpty)
    }

    @Test("A companion for the simulator is found by its command line even when idb's state file does not list it, and is stopped")
    func findsAndStopsUnlistedCompanion() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fake-companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A process whose executable is named idb_companion, started with the simulator's id.
        let executable = directory.appendingPathComponent("idb_companion")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/yes"), to: executable)
        let udid = "TEST-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--udid", udid]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        #expect(IDBRecovery.companionPIDs(udid: udid) == [process.processIdentifier])
        #expect(IDBRecovery.companionPIDs(udid: "TEST-OTHER").isEmpty, "another simulator's companion is left alone")
        #expect(IDBRecovery.restartCompanion(udid: udid, directory: directory.path, now: Date().addingTimeInterval(100_000)))
        process.waitUntilExit()
        #expect(!process.isRunning)
        #expect(IDBRecovery.companionPIDs(udid: udid).isEmpty)
    }
}

@Suite("idb device control: read_screen, find, tap by number")
struct IDBScreenReadingTests {
    private func control(_ nodes: [String]) throws -> (IDBDeviceControl, FakeIDB, DeviceValidationContext) {
        let fake = try FakeIDB(tree: "[" + nodes.joined(separator: ",\n") + "]")
        let root = ProductFixtures.tempDir()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (IDBDeviceControl(executable: fake.executable, preferredUDID: "SIM-1", bootedSimulators: { [] }), fake, DeviceValidationContext(projectRoot: root, repository: nil))
    }

    private let root = node("Application", label: "Demo", x: 0, y: 0, w: 402, h: 874)

    @Test("read_screen gives the short digest first, then only what changed")
    func firstThenDiff() async throws {
        let one = [root, node("Button", label: "Settings", x: 100, y: 200, w: 80, h: 44), node("Button", label: "Orders", x: 20, y: 500, w: 100, h: 50)]
        let (device, fake, context) = try control(one)
        let first = try await device.run(DeviceCommand(.readScreen), on: simulator, context: context)
        #expect(first.text.contains("Controls:") && first.text.contains("#1 button “Orders”") || first.text.contains("#1 button “Settings”"))
        let second = try await device.run(DeviceCommand(.readScreen), on: simulator, context: context)
        #expect(second.text.hasPrefix("Screen unchanged"), "\(second.text)")
        let forced = try await device.run(DeviceCommand(.readScreen, ["mode": .string("full")]), on: simulator, context: context)
        #expect(forced.text.contains("Controls:"))
        #expect(fake.calls.filter { $0.hasPrefix("ui describe-all") }.count == 3)
    }

    @Test("find lists matches with their numbers and positions, and says when nothing matches")
    func find() async throws {
        let (device, _, context) = try control([root, node("Button", label: "Settings", x: 100, y: 200, w: 80, h: 44), node("Button", label: "Setup guide", x: 100, y: 300, w: 80, h: 44)])
        let found = try await device.run(DeviceCommand(.find, ["text": .string("set")]), on: simulator, context: context)
        #expect(found.text.contains("button “Settings”") && found.text.contains("button “Setup guide”") && found.text.contains("(140,222)"))
        let none = try await device.run(DeviceCommand(.find, ["text": .string("zebra")]), on: simulator, context: context)
        #expect(none.text.contains("Nothing on screen matches “zebra”"))
    }

    @Test("tap by number taps the element's current centre, and refuses a number that was never given or is no longer there")
    func tapByNumber() async throws {
        let (device, fake, context) = try control([root, node("Button", label: "Settings", x: 100, y: 200, w: 80, h: 44)])
        await #expect(throws: DeviceControlError.self) { _ = try await device.run(DeviceCommand(.tap, ["handle": .string("#1")]), on: simulator, context: context) }
        _ = try await device.run(DeviceCommand(.readScreen), on: simulator, context: context)
        let result = try await device.run(DeviceCommand(.tap, ["handle": .string("#1")]), on: simulator, context: context)
        #expect(result.text == "Tapped #1 “Settings” at (140, 222).")
        #expect(fake.calls.contains("ui tap --udid SIM-1 140 222"))
        await #expect(throws: DeviceControlError.self) { _ = try await device.run(DeviceCommand(.tap, ["handle": .string("#9")]), on: simulator, context: context) }
    }
}

private final class FakeVision: ScreenQuestioning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var asked: [String] = []
    func answer(question: String, screenshot: Data, mimeType: String) async throws -> String {
        lock.withLock { asked.append(question) }
        #expect(!screenshot.isEmpty && ["image/jpeg", "image/png"].contains(mimeType))
        return "The cart icon is at the top right."
    }
}

@Suite("idb device control: look (vision on demand)")
struct IDBLookTests {
    private func control(vision: (any ScreenQuestioning)?) throws -> (IDBDeviceControl, DeviceValidationContext) {
        let fake = try FakeIDB(tree: "[" + node("Application", label: "Demo", x: 0, y: 0, w: 402, h: 874) + "]")
        let root = ProductFixtures.tempDir()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (IDBDeviceControl(executable: fake.executable, preferredUDID: "SIM-1", questioner: vision, bootedSimulators: { [] }), DeviceValidationContext(projectRoot: root, repository: nil))
    }

    @Test("Without a vision model, look says what to use instead and fails softly")
    func noKey() async throws {
        let (device, context) = try control(vision: nil)
        let result = try await device.run(DeviceCommand(.look, ["question": .string("which icon is the cart?")]), on: simulator, context: context)
        #expect(!result.ok && result.text.contains("GEMINI_API_KEY") && result.text.contains("read_screen"))
    }

    @Test("The answer is text, the same screen and question are answered once, and another question asks again")
    func answersAndCaches() async throws {
        let vision = FakeVision()
        let (device, context) = try control(vision: vision)
        let first = try await device.run(DeviceCommand(.look, ["question": .string("which icon is the cart?")]), on: simulator, context: context)
        #expect(first.ok && first.text == "The cart icon is at the top right.")
        _ = try await device.run(DeviceCommand(.look, ["question": .string("which icon is the cart?")]), on: simulator, context: context)
        #expect(vision.asked.count == 1)
        _ = try await device.run(DeviceCommand(.look, ["question": .string("is there a badge?")]), on: simulator, context: context)
        #expect(vision.asked.count == 2)
    }

    @Test("look needs a question, and is read-only")
    func shape() async throws {
        let (device, context) = try control(vision: FakeVision())
        await #expect(throws: DeviceControlError.self) { _ = try await device.run(DeviceCommand(.look), on: simulator, context: context) }
        #expect(DeviceCommandCatalog.spec(for: .look).risk == .readOnly && DeviceCommandCatalog.spec(for: .readScreen).risk == .readOnly && DeviceCommandCatalog.spec(for: .find).risk == .readOnly)
    }

    @Test("list_apps keeps the answer short with a filter, and says when nothing matches")
    func appFilter() {
        let data = Data("""
        {"bundle_id":"com.apple.mobilesafari","name":"MobileSafari","process_state":"Running"}
        {"bundle_id":"com.apple.Preferences","name":"Settings","process_state":"Not Running"}
        """.utf8)
        #expect(IDBDeviceControl.summarizeApps(data, filter: "safari") == "com.apple.mobilesafari  MobileSafari [running]")
        #expect(IDBDeviceControl.summarizeApps(data, filter: "zzz") == "No app matches “zzz”.")
        #expect(IDBDeviceControl.summarizeApps(data).split(separator: "\n").count == 2)
    }

    @Test("The booted simulator is read from simctl's JSON, across runtimes, ignoring shut-down devices")
    func bootedFromSimctl() {
        let data = Data("""
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"udid":"A","name":"iPhone 17","state":"Shutdown"},
          {"udid":"B","name":"iPhone 17 Pro","state":"Booted"}],
         "com.apple.CoreSimulator.SimRuntime.iOS-18-2":[{"udid":"C","name":"iPhone 16","state":"Booted"}]}}
        """.utf8)
        let booted = IDBDeviceControl.parseBootedSimulators(data)
        #expect(booted.map(\.udid) == ["C", "B"] || booted.map(\.udid) == ["B", "C"])
        #expect(booted.first { $0.udid == "B" }?.osVersion == "iOS 26.5" && booted.allSatisfy { $0.isBooted && $0.kind == .simulator })
        #expect(IDBDeviceControl.parseBootedSimulators(Data("{}".utf8)).isEmpty && IDBDeviceControl.parseBootedSimulators(Data("junk".utf8)).isEmpty)
    }
}
