import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// The command-line flags of a harness launch. Write a value as `--name=value`. The `--name value` form is also read, but a bare path or key on
/// the command line makes macOS treat it as a document to open, and then the window never appears; so use the `=` form for every flag.
struct LaunchOptions {
    let arguments: [String]

    init(_ arguments: [String] = CommandLine.arguments) { self.arguments = arguments }

    func has(_ flag: String) -> Bool { arguments.contains(flag) || arguments.contains { $0.hasPrefix(flag + "=") } }

    func value(_ name: String) -> String? {
        if let joined = arguments.first(where: { $0.hasPrefix(name + "=") }) { return String(joined.dropFirst(name.count + 1)) }
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }
}

/// Everything that exists only to drive and verify the app from the command line (screenshots, opening a section, starting a case, replaying a
/// recorded conversation, measuring layout). It lives in one place and is compiled only into debug builds, so a shipped app ignores the flags.
///
///     --snapshot=PATH [--delay=S] [--window-size=WxH] [--light|--dark] [--collapse-sidebar] [--send-keys=cmd+3,...] [--exit]
///     --tab=Run|Tests|History|Skills|Simulator|Operate|Agent   --tests-select=KEY --history-select=RUN_ID       --run-case=KEY [--bundle-id=ID]
///     --operate-task="text" [--exit]
///     --agent-repo=PATH   --agent-scenario="text"    --agent-replay=FILE[,FILE] [--agent-replay-rate=N]
///     --dump-layout[=S]   --dump-layout-series=N   --device-run='{"kind":"list_apps"}'
enum LaunchHarness {
#if DEBUG
    /// Called once the application has launched: window-level actions.
    @MainActor
    static func applicationDidFinishLaunching() {
        let options = LaunchOptions()
        LayoutDump.schedule(from: options)
        if let json = options.value("--device-run") { runDeviceCommand(json) }
        guard let path = options.value("--snapshot") else { return }
        let delay = options.value("--delay").flatMap(Double.init) ?? 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { SnapshotCapture(path: path, options: options).captureWhenReady(attemptsLeft: 250) }
    }

    /// `--device-run='{"kind":"list_apps","arguments":{}}'`: runs one device command through the real lane on the booted simulator, prints the
    /// result and quits. It skips the approval a chat would ask for; it is a developer's check that the commands work, never the agents' path.
    @MainActor
    private static func runDeviceCommand(_ json: String) {
        Task { @MainActor in
            defer { fflush(stdout); NSApp.terminate(nil) }
            let root = AppCompositionRoot.fromEnvironment()
            guard let control = root.makeDeviceControl() else { print("DEVICE not available: idb not found"); return }
            guard let command = try? JSONDecoder().decode(DeviceCommand.self, from: Data(json.utf8)) else { print("DEVICE could not read the command JSON"); return }
            guard let target = await control.defaultTarget() else { print("DEVICE no booted simulator"); return }
            do {
                let result = try await control.run(command, on: target, context: DeviceValidationContext(projectRoot: root.projectRoot, repository: nil))
                print("DEVICE OK on \(target.name):\n\(result.text)")
            } catch {
                print("DEVICE FAILED: \(error.localizedDescription)")
            }
        }
    }

    /// Called when the main window appears: in-window actions that need the app's state.
    @MainActor
    static func windowDidAppear(workspace: WorkspaceState, caseRun: CaseRunState, agentChat: AgentChatState, operate: OperateState, history: RunHistoryState, tests: TestLibraryState) {
        let options = LaunchOptions()
        if let name = options.value("--tab"), let section = WorkspaceSection(launchName: name) { workspace.show(section) }
        // `--history-select <run id>` opens that past run in History (loading the list first), for screenshots.
        if let key = options.value("--tests-select") { tests.reload(); tests.selectedKey = key }
        if let id = options.value("--history-select") { Task { await history.load(); history.selectedID = id } }
        if let path = options.value("--agent-repo") { agentChat.setRepositoryPath(path) }
        if let text = options.value("--agent-scenario") { agentChat.send(text) }
        if let files = options.value("--agent-replay") {
            let lines = files.split(separator: ",").flatMap { ((try? String(contentsOfFile: String($0), encoding: .utf8)) ?? "").components(separatedBy: "\n") }
            let rate = options.value("--agent-replay-rate").flatMap(Int.init) ?? 400
            Task { await agentChat.replay(lines: lines, eventsPerSecond: rate) }
        }
        // `--operate-session=done|failed|ID`: shows the newest saved session with that status (or that id), for a screenshot of a finished task.
        if let which = options.value("--operate-session") {
            let match = operate.sessions.first { $0.status == which || $0.id.uuidString == which }
            if let match { operate.select(match.id) }
        }
        if let task = options.value("--operate-task") { runOperate(task, on: operate, options: options) }
        if let key = options.value("--run-case") { caseRun.start(key: key, bundleID: options.value("--bundle-id")) }
    }

    /// `--operate-task="..."` starts the Operate graph on a task and logs its events to stdout (`OPERATE ...`); with `--exit` the app quits when it ends.
    /// Reversible commands are allowed for the task, as the section's own default does.
    @MainActor
    private static func runOperate(_ task: String, on operate: OperateState, options: LaunchOptions) {
        var seen = 0
        let started = Date()
        func stamp() -> String { String(format: "%6.1fs", Date().timeIntervalSince(started)) }
        func log(_ text: String) { print("OPERATE \(stamp()) \(text)"); fflush(stdout) }
        var cancellables: [Any] = []
        cancellables.append(operate.$entries.sink { entries in
            while seen < entries.count {
                let entry = entries[seen]; seen += 1
                switch entry.kind {
                case .node: log("node \(entry.text)")
                case .tool: if let line = OperateCards.line(for: entry) { log("[goal \(entry.goal)] \(entry.agent): \(line.text.prefix(140))") }
                case .error: log("ERROR \(entry.text)")
                default: break
                }
            }
        })
        cancellables.append(operate.$blockedReason.sink { if let reason = $0 { log("BLOCKED \(reason) (phase \(operate.phase))") } })
        cancellables.append(operate.$goals.sink { goals in log("goals " + goals.map { "\($0.number):\($0.state.rawValue)" }.joined(separator: " ")) })
        cancellables.append(operate.$phase.sink { phase in
            guard case .finished(let done) = phase else { return }
            // The usage event follows the result; give it a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                log("FINISHED done=\(done)\n\(operate.summary)\nusage \(operate.usage)\ntime \(operate.workerTimeSummary)")
                if options.has("--exit") { NSApp.terminate(nil) }
            }
        })
        objc_setAssociatedObject(operate, Unmanaged.passUnretained(operate).toOpaque(), cancellables as NSArray, .OBJC_ASSOCIATION_RETAIN)
        operate.start(task)
    }

    /// A line for the harness log, printed only under `--dump-layout`.
    static func trace(_ line: @autoclosure () -> String) {
        let options = LaunchOptions()
        guard options.has("--dump-layout") || options.has("--dump-layout-series") else { return }
        print(line())
        fflush(stdout)
    }
#else
    @MainActor static func applicationDidFinishLaunching() {}
    @MainActor static func windowDidAppear(workspace: WorkspaceState, caseRun: CaseRunState, agentChat: AgentChatState, operate: OperateState, history: RunHistoryState, tests: TestLibraryState) {}
    static func trace(_ line: @autoclosure () -> String) {}
#endif
}
