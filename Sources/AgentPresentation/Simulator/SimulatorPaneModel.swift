import Foundation
import AgentCore

/// Where the simulator is presented. Purely presentational.
/// - `docked`: the embedded live mirror inside this window, with inspect highlights over it.
/// - `realWindow`: undocked; the real Simulator.app window is used (no highlights are possible there).
public enum SimulatorPlacement: String, Sendable, CaseIterable {
    case docked = "Docked", realWindow = "Real Simulator Window", hidden = "Hidden"
}

/// View state for the simulator pane. It owns no device logic: lifecycle goes through
/// `SimulatorSessionManager`, and docking, undocking or hiding only changes `placement`. Changing
/// placement never boots, shuts down or recreates the device (see the tests).
@MainActor
public final class SimulatorPaneModel: ObservableObject {
    @Published public private(set) var devices: [SimulatorDevice] = []
    @Published public var selectedUDID: String {
        didSet {
            guard selectedUDID != oldValue else { return }
            mirror.reset()
        }
    }
    @Published public private(set) var activeUDID: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var busyLabel: String?
    @Published public private(set) var lastError: String?
    @Published public var placement: SimulatorPlacement = .docked

    /// "Embedded Simulator Preview": the optional live framebuffer view. It is a visualization
    /// convenience only. Turning it off stops all frame capture and frees the last frame; the device,
    /// the real Simulator.app, UI inspection and test execution are unaffected.
    @Published public var isPreviewEnabled: Bool {
        didSet {
            defaults.set(isPreviewEnabled, forKey: Self.previewKey)
            if !isPreviewEnabled { mirror.reset() }
        }
    }
    public static let previewKey = "embeddedSimulatorPreview"

    /// One live framebuffer capture shared by the docked pane. Capture is read-only.
    public let mirror: SimulatorMirror

    private let manager: SimulatorSessionManager?
    private let openRealSimulator: @MainActor () -> Void
    private let defaults: UserDefaults
    /// The device the case runner targets (`SimulatorTargetConfiguration.current.udid`). The pane can show other devices,
    /// but test execution is wired to this one.
    public let runnerTargetUDID: String
    public let targetBundleID: String
    private var monitorTask: Task<Void, Never>?

    public init(manager: SimulatorSessionManager?, runnerTargetUDID: String = SimulatorTargetConfiguration.current.udid,
                targetBundleID: String = SimulatorTargetConfiguration.current.previewBundleID,
                defaults: UserDefaults = .standard,
                framebuffer: (any SimulatorFramebufferSource)? = nil,
                openRealSimulator: @escaping @MainActor () -> Void = {}) {
        self.manager = manager
        self.mirror = SimulatorMirror(source: framebuffer)
        self.openRealSimulator = openRealSimulator
        self.defaults = defaults
        // `bool(forKey:)` also understands launch-argument overrides (`-embeddedSimulatorPreview NO`), which arrive as strings.
        self.isPreviewEnabled = defaults.object(forKey: Self.previewKey) == nil ? true : defaults.bool(forKey: Self.previewKey)
        self.runnerTargetUDID = runnerTargetUDID
        self.targetBundleID = targetBundleID
        self.selectedUDID = runnerTargetUDID
    }

    // MARK: Derived

    public var selectedDevice: SimulatorDevice? { devices.first { $0.udid == selectedUDID } }
    public var deviceState: SimulatorDeviceState { selectedDevice?.state ?? .unknown }
    public var bootState: SimulatorBootState { SimulatorBootState(deviceState: selectedDevice?.state, isAvailable: selectedDevice?.isAvailable ?? true, known: selectedDevice != nil) }
    public var isSessionActive: Bool { activeUDID != nil && activeUDID == selectedUDID }
    public var canManage: Bool { manager != nil }
    public var isSimulatorVisible: Bool { placement == .docked }
    /// Frames are captured only when docked AND the preview is enabled; never for undocked or hidden.
    public var shouldStreamPreview: Bool { placement == .docked && isPreviewEnabled }

    /// True when the selected device is not the one test execution is wired to.
    public var selectionDiffersFromRunnerTarget: Bool { selectedUDID != runnerTargetUDID }

    public var deviceTitle: String { selectedDevice.map { "\($0.name)" } ?? "Simulator" }
    public var osTitle: String { selectedDevice?.osVersion ?? "" }

    // MARK: Presentation (never touches the device)

    /// Back to the embedded mirror. The device keeps running; Simulator.app is left as it is.
    public func dock() { placement = .docked }
    /// Use the real Simulator.app window. Only brings it to the front; the device is not touched.
    public func undock() { placement = .realWindow; openRealSimulator() }
    public func hide() { placement = .hidden }

    // MARK: Lifecycle (through the manager)

    public func refresh() async { await refresh(clearingError: true) }

    private func refresh(clearingError: Bool) async {
        guard let manager else { return }
        do {
            devices = try await manager.refresh()
            activeUDID = await manager.session?.udid
            if clearingError { lastError = nil }
        } catch { lastError = error.localizedDescription }
    }

    /// Hides the last error message (the person has read it).
    public func dismissError() { lastError = nil }

    public func select(udid: String) {
        selectedUDID = udid
    }

    /// Boots the selected device (if needed) and makes it the single active session.
    public func activateSelected() async {
        await perform("Booting \(selectedDevice?.name ?? "simulator")…") { manager in _ = try await manager.activate(udid: self.selectedUDID) }
    }

    public func shutdownActive() async {
        await perform("Shutting down…") { manager in try await manager.shutdownActiveDevice() }
    }

    public func installApp(at path: String) async {
        await perform("Installing app…") { manager in try await manager.installApp(at: path) }
    }

    public func launchTargetApp() async {
        await perform("Launching \(targetBundleID)…") { manager in try await manager.launchApp(bundleID: self.targetBundleID) }
    }

    /// Polls device state so the pane reflects boots and shutdowns that happen outside the app.
    public func startMonitoring(interval: TimeInterval = 3) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.isBusy { await self.refresh() }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func perform(_ label: String, _ work: (SimulatorSessionManager) async throws -> Void) async {
        guard let manager, !isBusy else { return }
        isBusy = true; busyLabel = label; lastError = nil
        defer { isBusy = false; busyLabel = nil }
        do { try await work(manager) } catch { lastError = error.localizedDescription }
        // Refresh device state, but keep the error of the action that just failed visible.
        await refresh(clearingError: false)
    }
}
