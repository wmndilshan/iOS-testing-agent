import Testing
import Foundation
@testable import AgentCore
@testable import AgentPresentation

@Suite("Command palette and run filters")
struct CommandPaletteTests {
    private let cases = [(key: "SAFARI-1", title: "Open a page"), (key: "DEMO-TC-872", title: "Login")]
    private let runs = [(id: "SAFARI-1-a", key: "SAFARI-1", outcome: "FAILED")]

    @Test("An empty query lists the sections first; a running case adds Stop")
    func empty() {
        let idle = CommandPalette.items(query: "", caseKeys: cases, runs: runs, isRunning: false)
        #expect(idle.prefix(WorkspaceSection.allCases.count).map(\.action) == WorkspaceSection.allCases.map { .show($0) })
        #expect(!idle.contains { $0.action == .stopRun })
        #expect(CommandPalette.items(query: "", caseKeys: cases, runs: runs, isRunning: true).contains { $0.action == .stopRun })
    }

    @Test("A query matches title or detail, every word must match, and a prefix ranks first")
    func query() {
        let hits = CommandPalette.items(query: "safari", caseKeys: cases, runs: runs, isRunning: false)
        #expect(hits.map(\.action) == [.runCase(key: "SAFARI-1"), .openRun(id: "SAFARI-1-a")])
        #expect(CommandPalette.items(query: "login run", caseKeys: cases, runs: runs, isRunning: false).map(\.action) == [.runCase(key: "DEMO-TC-872")])
        #expect(CommandPalette.items(query: "hist", caseKeys: cases, runs: runs, isRunning: false).first?.action == .show(.history))
        #expect(CommandPalette.items(query: "zzz", caseKeys: cases, runs: runs, isRunning: false).isEmpty)
    }

    @Test("Outcome filter: Other is everything that neither passed nor failed")
    func outcomes() {
        #expect(RunOutcomeFilter.all.includes("BLOCKED"))
        #expect(RunOutcomeFilter.passed.includes("PASSED") && !RunOutcomeFilter.passed.includes("FAILED"))
        #expect(RunOutcomeFilter.other.includes("BLOCKED") && RunOutcomeFilter.other.includes("RUNNING"))
        #expect(!RunOutcomeFilter.other.includes("PASSED") && !RunOutcomeFilter.other.includes("FAILED"))
    }
}

@MainActor
@Suite("Stale running runs")
struct StaleRunTests {
    @Test("A run marked RUNNING from long ago is INTERRUPTED; a recent one stays RUNNING")
    func stale() {
        func entry(_ age: TimeInterval) -> RunHistoryState.Entry {
            let report = CaseRunReport(testKey: "K", title: "T", mode: "LIVE", startedAt: Date().addingTimeInterval(-age), steps: [])
            return RunHistoryState.Entry(id: "K-\(Int(age))", report: report, evidenceDirectory: URL(fileURLWithPath: "/tmp/none"))
        }
        #expect(entry(3 * 86_400).outcome == "INTERRUPTED")
        #expect(entry(60).outcome == "RUNNING")
    }
}
