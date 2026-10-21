import Foundation
import AgentCore

/// `SimulatorManaging` over `xcrun simctl`. Uses only public, supported tooling: no private
/// CoreSimulator / SimulatorKit APIs. Arguments are passed as an array (never through a shell) and
/// identifiers are validated first.
public struct SimctlSimulatorClient: SimulatorManaging {
    public init() {}

    public func listDevices() async throws -> [SimulatorDevice] {
        let out = try await Self.run(["list", "devices", "-j"])
        return try SimctlDeviceListParser.parse(out)
    }

    public func boot(udid: String) async throws {
        try Self.validate(udid: udid)
        do { _ = try await Self.run(["boot", udid]) }
        catch SimulatorError.commandFailed(let text) where text.contains("current state: Booted") { /* already booted: fine */ }
    }

    /// `simctl bootstatus` blocks until the device has finished booting, so no polling is needed.
    public func awaitBoot(udid: String) async throws {
        try Self.validate(udid: udid)
        _ = try await Self.run(["bootstatus", udid])
    }

    public func shutdown(udid: String) async throws {
        try Self.validate(udid: udid)
        do { _ = try await Self.run(["shutdown", udid]) }
        catch SimulatorError.commandFailed(let text) where text.contains("current state: Shutdown") { /* already down: fine */ }
    }

    public func installApp(at path: String, udid: String) async throws {
        try Self.validate(udid: udid)
        guard path.hasSuffix(".app") else { throw SimulatorError.invalidArgument("expected a .app bundle") }
        _ = try await Self.run(["install", udid, path])
    }

    public func launchApp(bundleID: String, udid: String) async throws {
        try Self.validate(udid: udid)
        guard SimulatorSessionManager.isValidBundleID(bundleID) else { throw SimulatorError.invalidArgument("bundle identifier") }
        _ = try await Self.run(["launch", udid, bundleID])
    }

    public func terminateApp(bundleID: String, udid: String) async throws {
        try Self.validate(udid: udid)
        guard SimulatorSessionManager.isValidBundleID(bundleID) else { throw SimulatorError.invalidArgument("bundle identifier") }
        _ = try await Self.run(["terminate", udid, bundleID])
    }

    private static func validate(udid: String) throws {
        guard udid.range(of: #"^[0-9A-Fa-f\-]{36}$"#, options: .regularExpression) != nil else {
            throw SimulatorError.invalidArgument("UDID '\(udid)'")
        }
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = Toolchain.xcrun
            process.arguments = ["simctl"] + arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { throw SimulatorError.commandFailed("Could not run simctl: \(error.localizedDescription)") }
            // Drain stdout before waiting so a large device list cannot fill the pipe and stall simctl.
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw SimulatorError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "simctl exited with status \(process.terminationStatus)" : text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return data
        }.value
    }
}

/// Parses `xcrun simctl list devices -j`.
public enum SimctlDeviceListParser {
    public static func parse(_ data: Data) throws -> [SimulatorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else {
            throw SimulatorError.commandFailed("Unrecognized simctl device list output.")
        }
        var out: [SimulatorDevice] = []
        for (runtime, devices) in runtimes {
            // Only iOS runtimes: this tool tests iOS apps.
            guard runtime.contains("SimRuntime.iOS-") else { continue }
            let os = osVersion(fromRuntime: runtime)
            for d in devices {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                out.append(SimulatorDevice(udid: udid, name: name, osVersion: os,
                                           state: SimulatorDeviceState(simctlValue: d["state"] as? String),
                                           isAvailable: (d["isAvailable"] as? Bool) ?? true))
            }
        }
        return out.sorted { ($0.osVersion, $0.name) > ($1.osVersion, $1.name) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` -> `iOS 26.4`
    public static func osVersion(fromRuntime id: String) -> String {
        guard let tail = id.components(separatedBy: "SimRuntime.").last else { return id }
        let parts = tail.split(separator: "-")
        guard parts.count >= 2 else { return tail }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }
}
