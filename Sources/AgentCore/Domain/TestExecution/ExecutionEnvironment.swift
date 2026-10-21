import Foundation

/// Where a live execution runs. Only the simulator has a driver today; a physical device is a declared, refused environment.
public enum ExecutionEnvironmentKind: String, Codable, Sendable, CaseIterable {
    case simulator
    case physicalDevice
}
