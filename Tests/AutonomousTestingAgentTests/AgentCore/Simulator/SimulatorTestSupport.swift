import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// In-memory CoreSimulator stand-in. Records every lifecycle call so tests can assert that nothing
/// (docking, undocking, the preview toggle) reaches the device.
actor FakeSimulatorClient: SimulatorManaging {
    private(set) var devices: [SimulatorDevice]
    private(set) var bootCalls: [String] = []
    private(set) var shutdownCalls: [String] = []
    private(set) var installCalls: [(path: String, udid: String)] = []
    private(set) var launchCalls: [(bundle: String, udid: String)] = []
    private(set) var listCalls = 0
    private(set) var awaitCalls: [String] = []
    var failNextBoot: SimulatorError?

    static let phoneA = SimulatorDevice(udid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "iPhone 17", osVersion: "iOS 26.5", state: .shutdown)
    static let phoneB = SimulatorDevice(udid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", name: "iPhone 17 Pro", osVersion: "iOS 26.5", state: .shutdown)
    static let broken = SimulatorDevice(udid: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", name: "iPhone 5", osVersion: "iOS 12.0", state: .shutdown, isAvailable: false)

    struct Calls: Equatable { var boots: [String]; var shutdowns: [String]; var installs: Int; var launches: [String]; var launchUDIDs: [String] }
    func calls() -> Calls {
        Calls(boots: bootCalls, shutdowns: shutdownCalls, installs: installCalls.count,
              launches: launchCalls.map(\.bundle), launchUDIDs: launchCalls.map(\.udid))
    }

    init(devices: [SimulatorDevice] = [phoneA, phoneB, broken]) { self.devices = devices }

    func setState(_ state: SimulatorDeviceState, udid: String) {
        devices = devices.map { $0.udid == udid ? $0.with(state: state) : $0 }
    }
    func failBoot(with error: SimulatorError?) { failNextBoot = error }

    func listDevices() async throws -> [SimulatorDevice] { listCalls += 1; return devices }
    func boot(udid: String) async throws {
        if let e = failNextBoot { failNextBoot = nil; throw e }
        bootCalls.append(udid); setState(.booted, udid: udid)
    }
    func awaitBoot(udid: String) async throws { awaitCalls.append(udid) }
    func shutdown(udid: String) async throws { shutdownCalls.append(udid); setState(.shutdown, udid: udid) }
    func installApp(at path: String, udid: String) async throws { installCalls.append((path, udid)) }
    func launchApp(bundleID: String, udid: String) async throws { launchCalls.append((bundleID, udid)) }
    func terminateApp(bundleID: String, udid: String) async throws {}
}
