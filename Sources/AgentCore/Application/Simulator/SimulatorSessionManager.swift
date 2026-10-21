import Foundation

/// Owns the ONE active simulator session and keeps its lifecycle separate from any UI.
///
/// - `activate` is idempotent: activating the already-active device reuses the session and performs no
///   boot, so test cases share one running device instead of restarting it.
/// - Activating a different device ends the previous session first; a device this application booted is
///   shut down so exactly one managed instance runs at a time.
/// - Docking or detaching the display is a presentation concern and never reaches this type.
public actor SimulatorSessionManager {
    private let client: any SimulatorManaging
    private let clock: any ClockProtocol
    public private(set) var session: DeviceSession?
    public private(set) var devices: [SimulatorDevice] = []

    public init(client: any SimulatorManaging, clock: any ClockProtocol = SystemClock()) {
        self.client = client
        self.clock = clock
    }

    // MARK: Discovery

    @discardableResult
    public func refresh() async throws -> [SimulatorDevice] {
        devices = try await client.listDevices()
        return devices
    }

    public func device(udid: String) -> SimulatorDevice? { devices.first { $0.udid == udid } }

    public func state(of udid: String) async throws -> SimulatorDeviceState {
        try await refresh()
        guard let device = device(udid: udid) else { throw SimulatorError.deviceNotFound(udid) }
        return device.state
    }

    // MARK: Session

    /// Makes `udid` the single active session, booting it only if it is not already running.
    @discardableResult
    public func activate(udid: String) async throws -> DeviceSession {
        try await refresh()
        guard let target = device(udid: udid) else { throw SimulatorError.deviceNotFound(udid) }
        guard target.isAvailable else { throw SimulatorError.deviceUnavailable(target.name) }

        if let current = session, current.udid == udid, target.state == .booted { return current }

        if let current = session, current.udid != udid { try await endSession(current) }

        var bootedByUs = session?.udid == udid ? session!.bootedByApplication : false
        switch target.state {
        case .booted: break
        case .booting: try await client.awaitBoot(udid: udid)
        case .shutdown, .shuttingDown, .unknown:
            try await client.boot(udid: udid)
            bootedByUs = true
            try await client.awaitBoot(udid: udid)
        }
        try await refresh()
        let new = DeviceSession(udid: udid, bootedByApplication: bootedByUs, startedAt: clock.now())
        session = new
        return new
    }

    /// Ends the session. Shuts the device down only if this application booted it.
    public func deactivate() async throws {
        guard let current = session else { return }
        try await endSession(current)
    }

    /// Shuts the active device down and ends the session.
    public func shutdownActiveDevice() async throws {
        guard let current = session else { throw SimulatorError.noActiveSession }
        try await client.shutdown(udid: current.udid)
        session = nil
        try await refresh()
    }

    // MARK: Apps (require a booted, active device)

    public func installApp(at path: String) async throws {
        let udid = try await requireBootedSession()
        guard path.hasSuffix(".app") else { throw SimulatorError.invalidArgument("expected a .app bundle, got \(path)") }
        try await client.installApp(at: path, udid: udid)
    }

    public func launchApp(bundleID: String) async throws {
        let udid = try await requireBootedSession()
        guard Self.isValidBundleID(bundleID) else { throw SimulatorError.invalidArgument("bundle identifier '\(bundleID)'") }
        try await client.launchApp(bundleID: bundleID, udid: udid)
    }

    public func terminateApp(bundleID: String) async throws {
        let udid = try await requireBootedSession()
        guard Self.isValidBundleID(bundleID) else { throw SimulatorError.invalidArgument("bundle identifier '\(bundleID)'") }
        try await client.terminateApp(bundleID: bundleID, udid: udid)
    }

    public static func isValidBundleID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9]([A-Za-z0-9\-]*)(\.[A-Za-z0-9\-]+)+$"#, options: .regularExpression) != nil
    }

    // MARK: Private

    private func endSession(_ current: DeviceSession) async throws {
        session = nil
        if current.bootedByApplication {
            try await refresh()
            if device(udid: current.udid)?.state == .booted { try await client.shutdown(udid: current.udid) }
        }
        try await refresh()
    }

    private func requireBootedSession() async throws -> String {
        guard let current = session else { throw SimulatorError.noActiveSession }
        let state = try await state(of: current.udid)
        guard state == .booted else { throw SimulatorError.notBooted(device(udid: current.udid)?.name ?? current.udid) }
        return current.udid
    }
}
