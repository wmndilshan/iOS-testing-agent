import Foundation

/// Port over CoreSimulator device management. The concrete implementation lives in Infrastructure.
///
/// Lifecycle only: it can list, boot, shut down, install and launch. It has no input or interaction
/// operations, so it cannot tap, type or otherwise drive the app under test.
/// The read-only part of simulator management. Preflight depends on this alone, so it cannot boot, install or launch.
public protocol SimulatorListing: Sendable {
    func listDevices() async throws -> [SimulatorDevice]
}

public protocol SimulatorManaging: SimulatorListing {
    func listDevices() async throws -> [SimulatorDevice]
    func boot(udid: String) async throws
    /// Returns once the device has finished booting (no polling by callers).
    func awaitBoot(udid: String) async throws
    func shutdown(udid: String) async throws
    func installApp(at path: String, udid: String) async throws
    func launchApp(bundleID: String, udid: String) async throws
    func terminateApp(bundleID: String, udid: String) async throws
}
