import Foundation
import AgentCore

/// Runs the `idb` command line against one simulator. No shell is involved: arguments are passed as an array, anything
/// positional follows `--`, every call is bounded by a time limit, and error output is redacted.
public struct IDBClient: Sendable {
    let executable: URL
    let udid: String
    let timeLimit: TimeInterval

    public init(executable: URL, udid: String, timeLimit: TimeInterval = 30) {
        self.executable = executable
        self.udid = udid
        self.timeLimit = timeLimit
    }

    /// The idb install to use: `ATA_IDB_PATH`, the project's `.venv-idb`, then the usual system locations.
    public static func locate(projectRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let candidates = [environment["ATA_IDB_PATH"],
                          projectRoot.appendingPathComponent(".venv-idb/bin/idb").path,
                          "/opt/homebrew/bin/idb", "/usr/local/bin/idb"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Runs `idb <command> --udid <udid> [options] [-- positional...]` and returns standard output. A call that fails because idb is stuck (a stale
    /// lockfile, or a companion that stopped answering) repairs it and runs once more; see `IDBRecovery`.
    @discardableResult
    func run(_ command: [String], options: [String] = [], positional: [String] = []) async throws -> Data {
        do {
            return try await runOnce(command, options: options, positional: positional)
        } catch let error as DriverError {
            switch error {
            case .actionFailed(let message) where message.contains("lockfile"):
                // The call never ran, so running it again cannot repeat an action.
                guard IDBRecovery.clearStaleLock() else { throw error }
                return try await runOnce(command, options: options, positional: positional)
            case .timedOut:
                guard IDBRecovery.restartCompanion(udid: udid) else { throw error }
                // Only a read is run again: a tap or a typed text that timed out may have happened already.
                guard IDBRecovery.readOnlyCommands.contains(command.prefix(2).joined(separator: " ")) else { throw error }
                return try await runOnce(command, options: options, positional: positional)
            default:
                throw error
            }
        }
    }

    private func runOnce(_ command: [String], options: [String], positional: [String]) async throws -> Data {
        var arguments = command + ["--udid", udid] + options
        // `--` is only needed when a value could be read as an option (typed text). idb's tap and swipe take their
        // coordinates as a list, where the separator itself would be counted as a value.
        if !positional.isEmpty { arguments += (positional.contains { $0.hasPrefix("-") } ? ["--"] : []) + positional }
        return try await Self.execute(executable, arguments: arguments, label: "idb " + command.joined(separator: " "), limit: timeLimit)
    }

    /// A command that is not about one device (`list-targets`): no `--udid`. Not retried after a repair, since there is no companion to repair.
    func runGlobal(_ command: [String], options: [String] = []) async throws -> Data {
        try await Self.execute(executable, arguments: command + options, label: "idb " + command.joined(separator: " "), limit: timeLimit)
    }

    /// A PNG of the screen at `path`. idb takes it through its companion, which can go stale after days and then fail every screenshot while taps and
    /// tree reads still work; `simctl` reads the framebuffer itself, so it is the fallback and a run does not stop for it.
    func screenshot(to path: String) async throws {
        do {
            try await run(["screenshot"], positional: [path])
            if FileManager.default.fileExists(atPath: path) { return }
        } catch {
            // Fall through to simctl.
        }
        _ = try await runSimctl(["io", udid, "screenshot", path])
    }

    /// `xcrun simctl <arguments>` for what idb does not cover on a simulator (appearance, device log, boot and shutdown). Arguments are an array.
    func runSimctl(_ arguments: [String], limit: TimeInterval? = nil) async throws -> Data {
        try await Self.execute(Toolchain.xcrun, arguments: ["simctl"] + arguments, label: "simctl " + (arguments.first ?? ""), limit: limit ?? timeLimit)
    }

    /// Runs one process and returns its standard output. The only place idb or simctl is started from.
    private static func execute(_ executable: URL, arguments: [String], label: String, limit: TimeInterval) async throws -> Data {
        // ATA_TRACE=<file> appends how long each idb or simctl call took, for finding what makes a command slow.
        guard let traceFile = traceFile else { return try await run(executable, arguments: arguments, label: label, limit: limit) }
        let started = Date()
        defer { appendTrace(String(format: "%5.2fs  %@\n", Date().timeIntervalSince(started), label), to: traceFile) }
        return try await run(executable, arguments: arguments, label: label, limit: limit)
    }

    private static let traceFile = ProcessInfo.processInfo.environment["ATA_TRACE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    private static func appendTrace(_ line: String, to file: URL) {
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private static func run(_ executable: URL, arguments: [String], label: String, limit: TimeInterval) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { try process.run() } catch {
                    continuation.resume(throwing: DriverError.actionFailed("\(label) could not start: \(error.localizedDescription)"))
                    return
                }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: watchdog)

                let stdoutBox = DataBox()
                let stderrBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { stdoutBox.set(output.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                group.enter()
                DispatchQueue.global().async { stderrBox.set(errors.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                group.wait()
                let stdout = stdoutBox.value
                let stderr = stderrBox.value
                process.waitUntilExit()
                let timedOut = watchdog.isCancelled == false && process.terminationReason == .uncaughtSignal
                watchdog.cancel()

                guard process.terminationStatus == 0 else {
                    let message = SecretRedactor.redact(String(data: stderr, encoding: .utf8) ?? "")
                    continuation.resume(throwing: timedOut
                        ? DriverError.timedOut("\(label) exceeded \(Int(limit))s")
                        : DriverError.actionFailed("\(label) failed (status \(process.terminationStatus)): \(message.suffix(300))"))
                    return
                }
                continuation.resume(returning: stdout)
            }
        }
    }
}

extension IDBClient {
    /// An app launched from the command line can come up with its accessibility tree not exposed (idb sees only the root element)
    /// until it is brought to the foreground again. Switching to Settings and back, with no restart, so the session survives.
    func cycleForeground(to bundleID: String) async {
        for target in ["com.apple.Preferences", bundleID] {
            await launch(target)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func launchApp(_ bundleID: String) async { await launch(bundleID) }

    private func launch(_ bundleID: String) async {
        let udid = udid
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = Toolchain.xcrun
                process.arguments = ["simctl", "launch", udid, bundleID]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil {
                    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
                    process.waitUntilExit()
                    watchdog.cancel()
                }
                continuation.resume()
            }
        }
    }
}

/// Receives one pipe's bytes from a reader thread.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ newValue: Data) { lock.withLock { data = newValue } }
    var value: Data { lock.withLock { data } }
}
