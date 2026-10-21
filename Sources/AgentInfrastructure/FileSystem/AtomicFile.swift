import Foundation
import AgentCore

/// Atomic file replacement via POSIX `rename(2)`.
///
/// `FileManager.replaceItemAt` routes through file coordination, which was observed to hang
/// indefinitely inside iCloud-synced folders (this project lives in one). `rename(2)` on the same
/// volume is atomic, replaces an existing destination, and never invokes cloud coordination.
enum AtomicFile {
    static func write(_ data: Data, to destination: URL) throws {
        let dir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let temp = destination.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        let rc = temp.withUnsafeFileSystemRepresentation { t -> Int32 in
            destination.withUnsafeFileSystemRepresentation { d -> Int32 in rename(t, d) }
        }
        guard rc == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Atomic rename failed: \(reason)"])
        }
    }
}
