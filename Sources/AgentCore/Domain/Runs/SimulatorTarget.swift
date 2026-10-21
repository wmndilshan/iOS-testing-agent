import Foundation

/// Value describing the simulator and application selected for an execution context.
/// Developer-machine and deployment defaults are supplied by the application configuration boundary.
public struct SimulatorTarget: Sendable, Equatable {
    public let name: String
    public let osVersion: String
    public let udid: String
    public let bundleID: String
    public let previewBundleID: String

    public init(name: String, osVersion: String, udid: String, bundleID: String, previewBundleID: String) {
        self.name = name
        self.osVersion = osVersion
        self.udid = udid
        self.bundleID = bundleID
        self.previewBundleID = previewBundleID
    }
}
