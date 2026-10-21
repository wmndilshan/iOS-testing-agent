import Foundation

/// A simulator or a connected device idb can talk to.
public struct DeviceTarget: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case simulator, device, mac }

    public let udid: String
    public let name: String
    public let kind: Kind
    public let state: String
    public let osVersion: String
    public var id: String { udid }
    public var isBooted: Bool { state.lowercased() == "booted" }

    public init(udid: String, name: String, kind: Kind, state: String, osVersion: String) {
        self.udid = udid
        self.name = name
        self.kind = kind
        self.state = state
        self.osVersion = osVersion
    }
}
