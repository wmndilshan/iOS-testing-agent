import Foundation

/// What a command can do to the device, which decides how much approval it needs.
public enum DeviceCommandRisk: String, Codable, Sendable, Equatable, CaseIterable {
    /// Reads only: screenshots, the screen's elements, app lists, logs. Never changes the device.
    case readOnly
    /// Changes the device in a way that is easy to undo or repeat: a tap, opening a link, a location, a permission.
    case reversible
    /// Loses data or removes something: an uninstall, clearing the keychain or photos, deleting files, erasing the device.
    case destructive
}

/// Whether a command works on a real device too, or only on a simulator.
public enum DeviceTargetSupport: String, Codable, Sendable, Equatable {
    case anyTarget
    case simulatorOnly
}

public enum DeviceCommandGroup: String, CaseIterable, Codable, Sendable {
    case observe, input, app, environment, files, system
}
