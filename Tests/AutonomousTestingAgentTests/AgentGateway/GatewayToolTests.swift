import Testing
import Foundation
import AppKit
@testable import AgentCore
@testable import AgentGateway

private actor FakeControl: DeviceControlling {
    private(set) var ran: [DeviceCommand] = []
    private let booted = DeviceTarget(udid: "SIM-1", name: "iPhone 17", kind: .simulator, state: "Booted", osVersion: "iOS 26.5")
    func targets() async throws -> [DeviceTarget] { [booted] }
    func defaultTarget() async -> DeviceTarget? { booted }
    func run(_ command: DeviceCommand, on target: DeviceTarget, context: DeviceValidationContext) async throws -> DeviceCommandResult {
        ran.append(command)
        return DeviceCommandResult(text: "did \(command.kind.rawValue) on \(target.name)")
    }
}

private final class FakeProcess: CaseRunHandle, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var sentLines: [String] = []
    var sent: [String] { lock.withLock { sentLines } }
    init(script: @escaping @Sendable (FakeProcess) -> Void) {
        var captured: AsyncStream<String>.Continuation!
        lines = AsyncStream { captured = $0 }
        continuation = captured
        let me = self
        DispatchQueue.global().async { script(me) }
    }
    func emit(_ object: [String: Any]) { continuation.yield("@@EVENT " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)) }
    func finish() { continuation.finish() }
    func send(_ line: String) { lock.withLock { sentLines.append(line) } }
    func terminate() { continuation.finish() }
}

private final class FakeLauncher: CaseRunLaunching, @unchecked Sendable {
    let process: FakeProcess
    private let lock = NSLock()
    private var argumentLists: [[String]] = []
    var arguments: [[String]] { lock.withLock { argumentLists } }
    init(_ process: FakeProcess) { self.process = process }
    func launch(arguments: [String]) throws -> any CaseRunHandle { lock.withLock { argumentLists.append(arguments) }; return process }
}

private func folder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Gateway device tools")
struct GatewayDeviceToolTests {
    private func gateway(_ control: FakeControl?) -> Gateway {
        Gateway(tools: GatewayCatalogue.tools(GatewayServices(projectRoot: folder(), deviceControl: control, launcher: nil)))
    }

    @Test("The catalogue offers the device tools, the case tools and planning, each with a schema")
    func catalogue() {
        let names = gateway(nil).tools.map(\.name)
        #expect(names == ["device_observe", "device_input", "device_app", "device_environment", "device_files", "device_system",
                          "device_sequence", "list_device_commands", "list_cases", "read_case", "write_case", "generate_cases", "run_case", "list_runs", "get_report", "plan_tests"])
        for tool in gateway(nil).tools { #expect(tool.inputSchema != .null && !tool.description.isEmpty, Comment(rawValue: tool.name)) }
    }

    @Test("The device tools' schemas come from the command catalogue and mark the read-only group")
    func schemas() throws {
        let tools = gateway(nil).tools
        let input = try #require(tools.first { $0.name == "device_input" })
        guard case .dictionary(let schema) = input.inputSchema, case .dictionary(let props)? = schema["properties"], case .dictionary(let command)? = props["command"],
              case .array(let options)? = command["enum"] else { Issue.record("no command enum"); return }
        #expect(options.contains(.string("tap")) && options.contains(.string("type_text")) && props["confirm"] != nil)
        #expect(tools.first { $0.name == "device_observe" }?.readOnly == true && input.readOnly == false)
    }

    @Test("A read-only and a reversible command run on the booted simulator")
    func runs() async {
        let control = FakeControl()
        let gateway = gateway(control)
        let read = await gateway.call("device_observe", arguments: ["command": .string("read_screen")])
        #expect(!read.isError && read.plainText == "did read_screen on iPhone 17")
        let tap = await gateway.call("device_input", arguments: ["command": .string("tap"), "x": .int(10), "y": .int(20)])
        #expect(!tap.isError)
        let ran = await control.ran
        #expect(ran.map(\.kind) == [.readScreen, .tap])
    }

    @Test("A destructive command is refused until the call confirms it, and nothing runs in between")
    func destructive() async {
        let control = FakeControl()
        let gateway = gateway(control)
        let refused = await gateway.call("device_app", arguments: ["command": .string("uninstall_app"), "bundle_id": .string("com.apple.mobilesafari")])
        #expect(refused.isError && refused.plainText.contains("confirm=true"))
        let none = await control.ran
        #expect(none.isEmpty)
        let confirmed = await gateway.call("device_app", arguments: ["command": .string("uninstall_app"), "bundle_id": .string("com.apple.mobilesafari"), "confirm": .bool(true)])
        #expect(!confirmed.isError)
        let ran = await control.ran
        #expect(ran.map(\.kind) == [.uninstallApp])
    }

    @Test("A command outside the tool's group, a bad argument and a missing device are errors the agent can read")
    func errors() async {
        let gateway = gateway(FakeControl())
        let wrongGroup = await gateway.call("device_observe", arguments: ["command": .string("tap")])
        #expect(wrongGroup.isError && wrongGroup.plainText.contains("command must be one of"))
        let unknown = await gateway.call("device_input", arguments: ["command": .string("tap"), "nonsense": .int(1)])
        #expect(unknown.isError)
        let none = await Gateway(tools: GatewayCatalogue.tools(GatewayServices(projectRoot: folder(), deviceControl: nil, launcher: nil)))
            .call("device_observe", arguments: ["command": .string("read_screen")])
        #expect(none.isError && none.plainText.contains("idb was not found"))
        let missing = await gateway.call("no_such_tool", arguments: [:])
        #expect(missing.isError && missing.plainText.contains("device_observe"))
    }

    @Test("device_sequence runs the steps in order, returns the screen after them, and stops at the first failure")
    func sequence() async {
        let control = FakeControl()
        let gateway = gateway(control)
        let ok = await gateway.call("device_sequence", arguments: ["settle_ms": .int(0), "steps": .array([
            .dictionary(["command": .string("tap"), "label": .string("Search")]),
            .dictionary(["command": .string("type_text"), "text": .string("watches")]),
            .dictionary(["command": .string("press_key"), "key": .string("return")])])])
        #expect(!ok.isError && ok.plainText.contains("step 3 press_key") && ok.plainText.contains("--- the screen now"))
        let ran = await control.ran
        #expect(ran.map(\.kind) == [.tap, .typeText, .pressKey, .readScreen])
        let bad = await gateway.call("device_sequence", arguments: ["settle_ms": .int(0), "steps": .array([
            .dictionary(["command": .string("tap"), "label": .string("A")]), .dictionary(["command": .string("tap")]), .dictionary(["command": .string("tap"), "label": .string("C")])])])
        #expect(bad.isError && bad.plainText.contains("Stopped at step 2"))
        let after = await control.ran
        #expect(after.count == 5, "step 1 ran, step 2 was refused, step 3 never ran")
    }

    @Test("device_sequence refuses a destructive step even when confirm is given, and anything outside the device tools")
    func sequenceRefusals() async {
        let control = FakeControl()
        let gateway = gateway(control)
        let destructive = await gateway.call("device_sequence", arguments: ["steps": .array([.dictionary(["command": .string("uninstall_app"), "bundle_id": .string("a.b"), "confirm": .bool(true)])])])
        #expect(destructive.isError && destructive.plainText.contains("on its own"))
        let system = await gateway.call("device_sequence", arguments: ["steps": .array([.dictionary(["command": .string("erase_target")])])])
        #expect(system.isError)
        let none = await gateway.call("device_sequence", arguments: ["steps": .array([])])
        #expect(none.isError)
        let ran = await control.ran
        #expect(ran.isEmpty)
    }

    @Test("The screenshot hint says how the shrunk picture maps to screen points")
    func screenshotHint() throws {
        func png(_ width: Int, _ height: Int) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }
        let hint = ScreenshotGeometry.hint(full: png(1206, 2622), sent: png(506, 1100))
        #expect(hint.contains("506×1100 px for a 402×874 point screen") && hint.contains("× 0.79"), Comment(rawValue: hint))
        #expect(ScreenshotGeometry.hint(full: Data(), sent: Data()).isEmpty)
    }

    @Test("Anything that looks like a secret is redacted from a tool's text before it leaves")
    func redaction() async {
        struct Leaky: DeviceControlling {
            func targets() async throws -> [DeviceTarget] { [] }
            func defaultTarget() async -> DeviceTarget? { DeviceTarget(udid: "S", name: "n", kind: .simulator, state: "Booted", osVersion: "1") }
            func run(_ command: DeviceCommand, on target: DeviceTarget, context: DeviceValidationContext) async throws -> DeviceCommandResult {
                DeviceCommandResult(text: "key AIzaSyA1234567890abcdefghijklmnopqrstu was printed")
            }
        }
        let gateway = Gateway(tools: GatewayCatalogue.tools(GatewayServices(projectRoot: folder(), deviceControl: Leaky(), launcher: nil)))
        let result = await gateway.call("device_observe", arguments: ["command": .string("read_screen")])
        #expect(!result.plainText.contains("AIzaSy") && result.plainText.contains("[REDACTED"))
    }
}

@Suite("Gateway case tools")
struct GatewayCaseToolTests {
    private func services(_ root: URL, launcher: (any CaseRunLaunching)? = nil, environment: [String: String] = [:]) -> GatewayServices {
        GatewayServices(projectRoot: root, deviceControl: nil, launcher: launcher, environment: environment)
    }

    private let steps: AnyCodableValue = .array([.dictionary(["action": .string("Open Safari"), "expected": .string("Safari is open")])])

    @Test("A case is written, listed and read back; an existing key is refused unless an agent-written case is replaced")
    func writeListRead() async {
        let gateway = Gateway(tools: GatewayCatalogue.tools(services(folder())))
        let written = await gateway.call("write_case", arguments: ["key": .string("demo-1"), "title": .string("Demo"), "steps": steps])
        #expect(!written.isError && written.plainText.contains("DEMO-1"))
        #expect((await gateway.call("list_cases", arguments: [:])).plainText.contains("DEMO-1 — Demo (1 steps)"))
        #expect((await gateway.call("read_case", arguments: ["key": .string("DEMO-1")])).plainText.contains("1. Open Safari → expect: Safari is open"))
        let again = await gateway.call("write_case", arguments: ["key": .string("DEMO-1"), "title": .string("Demo"), "steps": steps])
        #expect(again.isError)
        let replaced = await gateway.call("write_case", arguments: ["key": .string("DEMO-1"), "title": .string("Demo 2"), "steps": steps, "replace": .bool(true)])
        #expect(!replaced.isError)
    }

    @Test("Cases fetched earlier from AIO and cached are listed and readable too; a case of the project's own wins")
    func cachedCases() async throws {
        let root = folder()
        let cache = root.appendingPathComponent("Scripts/AIO/generated", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try """
        # NME-1: Cached case

        ## Steps

        | # | Step | Test Data | Expected Result |
        |---|------|-----------|-----------------|
        | 1 | Tap Collection | | The Collection screen is shown |
        """.write(to: cache.appendingPathComponent("NME-1.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: cache.appendingPathComponent("NME-1_detail.json"), atomically: true, encoding: .utf8)
        let gateway = Gateway(tools: GatewayCatalogue.tools(services(root)))
        let listing = (await gateway.call("list_cases", arguments: [:])).plainText
        #expect(listing.contains("NME-1 — Cached case (1 steps)") && !listing.contains("detail"))
        #expect((await gateway.call("read_case", arguments: ["key": .string("NME-1")])).plainText.contains("1. Tap Collection → expect: The Collection screen is shown"))
    }

    @Test("Bad input is refused with the reason: a bad key, no steps, a step with no expected result")
    func validation() async {
        let gateway = Gateway(tools: GatewayCatalogue.tools(services(folder())))
        #expect((await gateway.call("write_case", arguments: ["key": .string("bad key!"), "title": .string("t"), "steps": steps])).isError)
        #expect((await gateway.call("write_case", arguments: ["key": .string("OK-1"), "title": .string("t"), "steps": .array([])])).isError)
        let noExpected: AnyCodableValue = .array([.dictionary(["action": .string("x")])])
        #expect((await gateway.call("write_case", arguments: ["key": .string("OK-1"), "title": .string("t"), "steps": noExpected])).isError)
        #expect((await gateway.call("read_case", arguments: ["key": .string("../etc")])).isError)
    }

    @Test("run_case passes its flags, answers the password from the environment, denies approvals, and reports each step")
    func runCase() async {
        let process = FakeProcess { p in
            p.emit(["t": "case", "key": "DEMO-1", "title": "Demo", "steps": [["number": 1, "text": "Open"], ["number": 2, "text": "Check"]]])
            p.emit(["t": "prompt", "id": "password", "kind": "password", "title": "Password", "message": "m", "secure": true])
            p.emit(["t": "prompt", "id": "approve-1", "kind": "approval", "title": "Approve", "message": "m", "secure": false])
            p.emit(["t": "row", "id": "1.a", "number": 1, "intent": "Open", "action": "tap", "status": "passed", "detail": "ok"])
            p.emit(["t": "row", "id": "2.a", "number": 2, "intent": "Check", "action": "judge", "status": "failed", "detail": "wrong screen"])
            p.emit(["t": "done", "outcome": "FAILED", "passed": 1, "failed": 1, "skipped": 0, "failedStep": 2, "resumable": true])
            Thread.sleep(forTimeInterval: 0.05)
            p.finish()
        }
        let launcher = FakeLauncher(process)
        let gateway = Gateway(tools: GatewayCatalogue.tools(services(folder(), launcher: launcher, environment: ["TEST_USER_PASSWORD": "s3cret", "TEST_USER_USERNAME": "tester"])))
        let messages = ProgressLog()
        let result = await gateway.call("run_case", arguments: ["key": .string("demo-1"), "bundle_id": .string("com.apple.mobilesafari"), "start_step": .int(2)],
                                        progress: { message, _ in messages.add(message) })
        #expect(result.isError && result.plainText.contains("DEMO-1: FAILED — passed 1, failed 1"))
        #expect(result.plainText.contains("step 1 [passed] Open — ok") && result.plainText.contains("step 2 [failed] Check — wrong screen"))
        #expect(launcher.arguments.first == ["--run-case=DEMO-1", "--mode=LIVE_AUTONOMOUS_AFTER_LOGIN", "--events", "--bundle-id=com.apple.mobilesafari", "--start-step=2", "--username=tester"])
        #expect(process.sent == ["s3cret", "deny"], "\(process.sent)")
        #expect(messages.all.contains { $0.contains("step 2 [failed]") })
        #expect(!result.plainText.contains("s3cret"))
    }

    @Test("A run that asks for input the server does not have says what to set")
    func missingCredentials() async {
        let process = FakeProcess { p in
            p.emit(["t": "prompt", "id": "password", "kind": "password", "title": "Password", "message": "m", "secure": true])
            p.emit(["t": "done", "outcome": "FAILED", "passed": 0, "failed": 1, "skipped": 0, "failedStep": 1, "resumable": true])
            Thread.sleep(forTimeInterval: 0.05)
            p.finish()
        }
        let gateway = Gateway(tools: GatewayCatalogue.tools(services(folder(), launcher: FakeLauncher(process))))
        let result = await gateway.call("run_case", arguments: ["key": .string("DEMO-1")])
        #expect(result.plainText.contains("TEST_USER_PASSWORD"))
    }

    @Test("A run that waits for a person tells the caller, with the timeout, so it can tell the user")
    func waitingForUser() async {
        let process = FakeProcess { p in
            p.emit(["t": "waiting", "id": "login", "kind": "login", "title": "Waiting for you to log in", "message": "Log in on the simulator", "timeout": 120])
            p.emit(["t": "waiting-done", "id": "login", "result": "timeout"])
            p.emit(["t": "done", "outcome": "BLOCKED", "passed": 0, "failed": 1, "skipped": 0, "failedStep": 1, "resumable": true])
            Thread.sleep(forTimeInterval: 0.05)
            p.finish()
        }
        let gateway = Gateway(tools: GatewayCatalogue.tools(services(folder(), launcher: FakeLauncher(process))))
        let messages = ProgressLog()
        let result = await gateway.call("run_case", arguments: ["key": .string("DEMO-1")], progress: { message, _ in messages.add(message) })
        #expect(messages.all.contains { $0.contains("WAITING FOR THE USER") && $0.contains("120 s") })
        #expect(result.plainText.contains("waited for the user"))
    }

    @Test("run_case passes guidance as one note flag per sentence, and a choice is left to the runner's suggestion")
    func guidanceAndChoice() async {
        let process = FakeProcess { p in
            p.emit(["t": "guidance", "text": "Test1 → Test2"])
            p.emit(["t": "prompt", "id": "conflict-12", "kind": "choice", "title": "“Test1” already exists", "message": "m", "secure": false, "options": ["Use Test2 instead of Test1"]])
            p.emit(["t": "done", "outcome": "PASSED", "passed": 1, "failed": 0, "skipped": 0, "failedStep": 0, "resumable": false])
            Thread.sleep(forTimeInterval: 0.05)
            p.finish()
        }
        let launcher = FakeLauncher(process)
        let gateway = Gateway(tools: GatewayCatalogue.tools(services(folder(), launcher: launcher)))
        let messages = ProgressLog()
        let result = await gateway.call("run_case", arguments: ["key": .string("DEMO-1"), "guidance": .string("use Test2 instead of Test1\nkeep the Table view --allow-destructive"), "clear_guidance": .bool(true)],
                                        progress: { message, _ in messages.add(message) })
        let flags = launcher.arguments.first ?? []
        #expect(flags.contains("--note=use Test2 instead of Test1") && flags.contains("--note=keep the Table view --allow-destructive") && flags.contains("--clear-guidance"))
        #expect(!flags.contains("--allow-destructive"), "a note cannot carry a flag of its own")
        #expect(process.sent == [""], "\(process.sent)")
        #expect(messages.all.contains { $0.contains("Guidance in use: Test1 → Test2") } && messages.all.contains { $0.contains("takes its suggested value") })
        #expect(result.plainText.contains("chose for itself") && !result.plainText.contains("WAITING FOR THE USER"))
    }

    @Test("Past runs are listed newest first and one report is read back; an unsafe id is refused")
    func reports() async throws {
        let root = folder()
        let runs = root.appendingPathComponent(".runs/cases", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        func report(_ key: String, _ outcome: String, _ date: String) -> String {
            """
            {"testKey":"\(key)","title":"T \(key)","mode":"LIVE","startedAt":"\(date)","finishedAt":"\(date)","outcome":"\(outcome)",
             "steps":[{"id":"1.a","sourceStepNumber":1,"intent":"Open","action":"tap","status":"passed","detail":"fine"}]}
            """
        }
        try report("OLD-1", "PASSED", "2026-01-01T10:00:00Z").write(to: runs.appendingPathComponent("OLD-1-1.json"), atomically: true, encoding: .utf8)
        try report("NEW-1", "FAILED", "2026-02-01T10:00:00Z").write(to: runs.appendingPathComponent("NEW-1-2.json"), atomically: true, encoding: .utf8)
        let gateway = Gateway(tools: GatewayCatalogue.tools(services(root)))
        let list = (await gateway.call("list_runs", arguments: [:])).plainText.split(separator: "\n")
        #expect(list.first?.hasPrefix("NEW-1-2 | NEW-1 | FAILED") == true && list.count == 2)
        let one = await gateway.call("get_report", arguments: ["run_id": .string("NEW-1-2")])
        #expect(one.plainText.contains("Outcome: FAILED") && one.plainText.contains("step 1 [passed] Open — fine"))
        #expect((await gateway.call("get_report", arguments: ["run_id": .string("../secrets")])).isError)
        #expect((await gateway.call("get_report", arguments: ["run_id": .string("missing")])).isError)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var all: [String] { lock.withLock { messages } }
    func add(_ message: String) { lock.withLock { messages.append(message) } }
}
