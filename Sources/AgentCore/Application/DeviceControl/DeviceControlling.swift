import Foundation

/// What can go wrong with a device command, in words an agent or a person can act on.
public enum DeviceControlError: Error, LocalizedError, Equatable {
    case invalid(String)
    case unsupportedOnTarget(String)
    case denied
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): "The command is not valid: \(reason)"
        case .unsupportedOnTarget(let reason): reason
        case .denied: "The person did not allow this command. Nothing was changed."
        case .failed(let reason): reason
        }
    }
}

/// Runs a validated device command on a target. The app owns the one implementation; the agent process only ever sends requests.
public protocol DeviceControlling: Sendable {
    /// The simulators and devices that can be controlled.
    func targets() async throws -> [DeviceTarget]
    /// The target commands go to when none is named.
    func defaultTarget() async -> DeviceTarget?
    /// `context` says where host files may be read from and results written to. The command is validated again here, whatever the caller did.
    func run(_ command: DeviceCommand, on target: DeviceTarget, context: DeviceValidationContext) async throws -> DeviceCommandResult
}
