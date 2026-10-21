import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("idb recovery")
struct IDBRecoveryTests {
    private func makeDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "idb-recovery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("A lockfile older than the minimum age is removed")
    func removesStaleLock() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/state.lock", contents: nil)
        #expect(IDBRecovery.clearStaleLock(directory: dir, minimumAge: 5, now: Date().addingTimeInterval(60)))
        #expect(!FileManager.default.fileExists(atPath: dir + "/state.lock"))
    }

    @Test("A fresh lockfile is left alone, since a live idb call may hold it")
    func keepsFreshLock() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/state.lock", contents: nil)
        #expect(!IDBRecovery.clearStaleLock(directory: dir, minimumAge: 5))
        #expect(FileManager.default.fileExists(atPath: dir + "/state.lock"))
    }

    @Test("Only reads are run again after a timeout")
    func readsOnly() {
        #expect(IDBRecovery.readOnlyCommands.contains("ui describe-all"))
        #expect(!IDBRecovery.readOnlyCommands.contains("ui tap"))
    }
}
