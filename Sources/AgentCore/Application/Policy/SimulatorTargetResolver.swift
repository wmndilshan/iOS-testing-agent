import Foundation

/// Picks the simulator a run actually uses. The configured device is only a preference: a person may have booted another one (an iPhone 17 Pro
/// instead of the iPhone 17), and aiming idb at a shut-down device makes every step fail with "no accessibility tree".
public enum SimulatorTargetResolver {
    public struct Resolution: Sendable, Equatable {
        public let target: SimulatorTarget
        /// A line for the run log: which device, and why it was chosen.
        public let note: String
    }

    /// 1. the configured device when it is booted; 2. another booted iPhone (the first, newest OS first); 3. the configured device, booted now;
    /// 4. the newest available iPhone, booted now. If nothing can be found or booted, the configured target is returned unchanged.
    public static func resolve(preferred: SimulatorTarget, manager: any SimulatorManaging) async -> Resolution {
        guard let devices = try? await manager.listDevices() else {
            return Resolution(target: preferred, note: "Simulator: \(preferred.name) (could not list devices)")
        }
        func target(_ device: SimulatorDevice) -> SimulatorTarget {
            SimulatorTarget(name: device.name, osVersion: device.osVersion, udid: device.udid, bundleID: preferred.bundleID, previewBundleID: preferred.previewBundleID)
        }
        let usable = devices.filter(\.isAvailable)
        if let device = usable.first(where: { $0.udid == preferred.udid && $0.state == .booted }) {
            return Resolution(target: preferred, note: "Simulator: \(device.name) (booted)")
        }
        let phones = usable.filter { $0.name.hasPrefix("iPhone") }
        let newestFirst: (SimulatorDevice, SimulatorDevice) -> Bool = { $0.osVersion.compare($1.osVersion, options: .numeric) == .orderedDescending }
        if let booted = phones.filter({ $0.state == .booted }).sorted(by: newestFirst).first {
            return Resolution(target: target(booted), note: "Simulator: \(booted.name) (booted; the configured \(preferred.name) is not running)")
        }
        let toBoot = usable.first(where: { $0.udid == preferred.udid }) ?? phones.sorted(by: newestFirst).first
        if let device = toBoot, (try? await manager.boot(udid: device.udid)) != nil, (try? await manager.awaitBoot(udid: device.udid)) != nil {
            return Resolution(target: device.udid == preferred.udid ? preferred : target(device), note: "Simulator: \(device.name) (booted for this run)")
        }
        return Resolution(target: preferred, note: "Simulator: \(preferred.name) is not booted and could not be started")
    }
}
