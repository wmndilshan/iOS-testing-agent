import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Run history")
@MainActor
struct RunHistoryStateTests {
    private func write(_ report: CaseRunReport, name: String, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(report).write(to: dir.appendingPathComponent("\(name).json"))
    }

    private func report(key: String, started: TimeInterval, outcome: String = "PASSED") -> CaseRunReport {
        var r = CaseRunReport(testKey: key, title: "T \(key)", mode: "LIVE", startedAt: Date(timeIntervalSince1970: started), steps: [
            .init(id: "s1", sourceStepNumber: 1, intent: "Tap A", action: "tap"),
            .init(id: "s2", sourceStepNumber: 1, intent: "Check A", action: "verifyOnly"),
            .init(id: "s3", sourceStepNumber: 2, intent: "Tap B", action: "tap")
        ])
        r.update("s1", status: .passed, detail: "ok")
        r.update("s2", status: .failed, detail: "A missing")
        r.closeOut(outcome: outcome)
        return r
    }

    @Test func testLoadsNewestFirstAndSkipsJunk() throws {
        let dir = ProductFixtures.tempDir()
        try write(report(key: "A-1", started: 1_000), name: "A-1-1000", to: dir)
        try write(report(key: "B-2", started: 2_000, outcome: "FAILED"), name: "B-2-2000", to: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("junk.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("active-run.lock"))
        let state = RunHistoryState(directory: dir)
        state.reload()
        #expect(state.entries.map(\.id) == ["B-2-2000", "A-1-1000"])
        #expect(state.entries[0].passed == false && state.entries[1].passed)
        #expect(state.entries[0].evidenceDirectory.lastPathComponent == "B-2-2000")
    }

    @Test("Loading off the main thread gives the same entries as reloading, clears the loading flag, and knows where each report lives")
    func testAsyncLoadMatchesReload() async throws {
        let dir = ProductFixtures.tempDir()
        try write(report(key: "A-1", started: 1_000), name: "A-1-1000", to: dir)
        try write(report(key: "B-2", started: 2_000), name: "B-2-2000", to: dir)
        let sync = RunHistoryState(directory: dir)
        sync.reload()
        let asynchronous = RunHistoryState(directory: dir)
        await asynchronous.load()
        #expect(asynchronous.entries.map(\.id) == sync.entries.map(\.id))
        #expect(asynchronous.isLoading == false)
        #expect(asynchronous.entries[0].reportURL.lastPathComponent == "B-2-2000.json")
        #expect(FileManager.default.fileExists(atPath: asynchronous.entries[0].reportURL.path))
    }

    @Test func testReadsTheOldFolderAndPrefersTheNewOne() throws {
        let new = ProductFixtures.tempDir(), old = ProductFixtures.tempDir()
        try write(report(key: "OLD-1", started: 1_000), name: "OLD-1-1000", to: old)
        try write(report(key: "DUP-1", started: 2_000, outcome: "FAILED"), name: "DUP-1-2000", to: old)
        try write(report(key: "DUP-1", started: 2_000, outcome: "PASSED"), name: "DUP-1-2000", to: new)
        let state = RunHistoryState(directory: new, legacyDirectory: old)
        state.reload()
        #expect(state.entries.map(\.id) == ["DUP-1-2000", "OLD-1-1000"])
        #expect(state.entries[0].passed, "the copy in the new folder wins")
        #expect(state.entries[1].rootDirectory.standardizedFileURL == old.standardizedFileURL, "evidence of an old run is read from the old folder")
    }

    @Test func testStepsAreGroupedBySourceStepWithFailureReason() throws {
        let dir = ProductFixtures.tempDir()
        try write(report(key: "A-1", started: 1_000), name: "A-1-1000", to: dir)
        let state = RunHistoryState(directory: dir)
        state.reload()
        let steps = try #require(state.entries.first).steps
        #expect(steps.map(\.id) == [1, 2])
        #expect(steps[0].status == .failed && steps[0].failureReason == "A missing")
        #expect(steps[1].status == .skipped)
    }

    @Test func testSelectionIsDroppedWhenTheRunDisappears() throws {
        let dir = ProductFixtures.tempDir()
        try write(report(key: "A-1", started: 1_000), name: "A-1-1000", to: dir)
        let state = RunHistoryState(directory: dir)
        state.reload()
        state.selectedID = "A-1-1000"
        #expect(state.selected?.key == "A-1")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("A-1-1000.json"))
        state.reload()
        #expect(state.selectedID == nil && state.entries.isEmpty)
    }

    @Test func testMissingDirectoryIsEmpty() {
        let state = RunHistoryState(directory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        state.reload()
        #expect(state.entries.isEmpty)
    }
}
