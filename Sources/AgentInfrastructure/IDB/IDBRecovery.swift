import Foundation
import Darwin
import AgentCore

/// Repairs the two ways `idb` gets stuck, so a run does not fail on a tool problem the person cannot see:
///
/// - **A stale lockfile.** idb serialises its state file with an exclusive lockfile (`/tmp/idb/state.lock`). If an idb process is killed while
///   it holds the lock, the file stays behind and every later idb call waits three seconds and fails with "Failed to open the lockfile".
/// - **An unresponsive companion.** `idb_companion` is a long-lived helper per simulator. When it stops answering, every idb call hangs until
///   its time limit. Stopping it lets idb start a fresh one on the next call.
///
/// It only ever signals a process that idb's own state file names for this simulator and whose executable really is `idb_companion`.
enum IDBRecovery {
    /// Commands that only read: running one again after a repair cannot repeat an action in the app.
    static let readOnlyCommands: Set<String> = ["ui describe-all", "ui describe-point", "screenshot", "list-apps", "describe", "list-targets", "get", "crash list", "crash show",
                                                 "notification list", "file ls", "file read", "file pull"]

    private static let restartLock = NSLock()
    nonisolated(unsafe) private static var lastRestart = Date.distantPast
    /// Companions are restarted at most this often, so a broken simulator cannot make runs kill them in a loop.
    private static let restartInterval: TimeInterval = 60

    /// Removes the lockfile when it is old enough that no live idb call can still hold it. Returns whether a file was removed.
    @discardableResult
    static func clearStaleLock(directory: String = "/tmp/idb", minimumAge: TimeInterval = 5, now: Date = Date()) -> Bool {
        let path = directory + "/state.lock"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) >= minimumAge else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    /// Stops the companion recorded for `udid` and clears idb's state, socket and lock files. Returns whether something was repaired.
    @discardableResult
    static func restartCompanion(udid: String, directory: String = "/tmp/idb", now: Date = Date()) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard now.timeIntervalSince(lastRestart) >= restartInterval else { return false }

        // The companions to stop: the one idb's state file records, and any other process that is a companion started for this simulator. A
        // companion that hung can be missing from the state file (idb forgets it), and would then be found by no one.
        var pids = Set<Int32>()
        if let data = FileManager.default.contents(atPath: directory + "/state"),
           let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for entry in entries where (entry["udid"] as? String) == udid {
                if let pid = (entry["pid"] as? Int).map(Int32.init), isCompanion(pid: pid) { pids.insert(pid) }
            }
        }
        pids.formUnion(companionPIDs(udid: udid))
        var stopped = false
        for pid in pids {
            kill(pid, SIGTERM)
            for _ in 0..<20 where kill(pid, 0) == 0 { usleep(100_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            stopped = true
        }
        var removed = false
        for name in ["state", "state.lock", "\(udid)_companion.sock"] {
            if (try? FileManager.default.removeItem(atPath: directory + "/" + name)) != nil { removed = true }
        }
        guard stopped || removed else { return false }
        lastRestart = now
        return true
    }

    /// Every running `idb_companion` that was started for `udid` (its `--udid` argument).
    static func companionPIDs(udid: String) -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        return pids.prefix(max(0, found)).filter { $0 > 0 && isCompanion(pid: $0) && arguments(of: $0).contains(udid) }
    }

    /// A process's arguments (`sysctl KERN_PROCARGS2`), or none when they cannot be read.
    static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard index < size else { return nil }
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            defer { index = end + 1 }
            return String(decoding: buffer[index..<end], as: UTF8.self)
        }
        _ = nextString()                                    // the executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding after it
        var arguments: [String] = []
        for _ in 0..<max(0, Int(argc)) { if let argument = nextString() { arguments.append(argument) } }
        return arguments
    }

    private static func isCompanion(pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return false }
        return URL(fileURLWithPath: String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)).lastPathComponent == "idb_companion"
    }
}
