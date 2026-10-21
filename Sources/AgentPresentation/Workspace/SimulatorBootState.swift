import Foundation
import AgentCore

/// Real boot state of the target simulator, read from `simctl`. Unknown until probed; never assumed.
public enum SimulatorBootState: String, Sendable, Equatable {
    case unknown = "Unknown"
    case booted = "Booted"
    case shutdown = "Shutdown"
    case booting = "Booting"
    case shuttingDown = "Shutting Down"
    case unavailable = "Unavailable"

    public var tone: StatusTone {
        switch self {
        case .booted: return .success
        case .booting, .shuttingDown: return .warning
        case .shutdown, .unavailable: return .failure
        case .unknown: return .neutral
        }
    }

    /// Maps the manager's device state. Unknown until a device list has been read; never assumed.
    public init(deviceState: SimulatorDeviceState?, isAvailable: Bool = true, known: Bool = true) {
        guard known, let deviceState else { self = .unknown; return }
        guard isAvailable else { self = .unavailable; return }
        switch deviceState {
        case .booted: self = .booted
        case .shutdown: self = .shutdown
        case .booting: self = .booting
        case .shuttingDown: self = .shuttingDown
        case .unknown: self = .unknown
        }
    }
}
