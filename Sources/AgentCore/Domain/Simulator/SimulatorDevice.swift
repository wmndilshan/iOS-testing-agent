import Foundation

/// Lifecycle state of a simulator device as reported by CoreSimulator.
public enum SimulatorDeviceState: String, Sendable, Equatable, Codable {
    case shutdown = "Shutdown"
    case booting = "Booting"
    case booted = "Booted"
    case shuttingDown = "Shutting Down"
    case unknown = "Unknown"

    public init(simctlValue: String?) {
        self = SimulatorDeviceState(rawValue: simctlValue ?? "") ?? .unknown
    }
}

/// One iOS simulator device known to CoreSimulator.
public struct SimulatorDevice: Sendable, Equatable, Identifiable, Codable {
    public var id: String { udid }
    public let udid: String
    public let name: String
    /// e.g. "iOS 26.5", derived from the runtime identifier.
    public let osVersion: String
    public let state: SimulatorDeviceState
    public let isAvailable: Bool

    public init(udid: String, name: String, osVersion: String, state: SimulatorDeviceState, isAvailable: Bool = true) {
        self.udid = udid; self.name = name; self.osVersion = osVersion; self.state = state; self.isAvailable = isAvailable
    }

    public func with(state: SimulatorDeviceState) -> SimulatorDevice {
        SimulatorDevice(udid: udid, name: name, osVersion: osVersion, state: state, isAvailable: isAvailable)
    }
}

/// The single device session the application manages. One session is active at a time and is reused
/// across test cases; switching presentation (docked / detached) never creates or ends a session.
public struct DeviceSession: Sendable, Equatable {
    public let udid: String
    /// True when this application booted the device (and therefore shuts it down when the session ends).
    public let bootedByApplication: Bool
    public let startedAt: Date

    public init(udid: String, bootedByApplication: Bool, startedAt: Date = Date()) {
        self.udid = udid; self.bootedByApplication = bootedByApplication; self.startedAt = startedAt
    }
}

public enum SimulatorError: Error, Sendable, Equatable, LocalizedError {
    case deviceNotFound(String)
    case deviceUnavailable(String)
    case noActiveSession
    case notBooted(String)
    case invalidArgument(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let id): return "No simulator device with UDID \(id)."
        case .deviceUnavailable(let name): return "\(name) is not available on this machine."
        case .noActiveSession: return "There is no active simulator session. Activate a device first."
        case .notBooted(let name): return "\(name) is not booted."
        case .invalidArgument(let why): return "Invalid argument: \(why)"
        case .commandFailed(let why): return why
        }
    }
}
