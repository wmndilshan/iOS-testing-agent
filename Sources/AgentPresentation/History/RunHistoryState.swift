import Foundation
import AgentCore

/// Past case runs read from `.runs/cases/<KEY>-<timestamp>.json` (and the old `.runs/aio`), newest first. Read-only: it never starts or changes a run.
@MainActor
public final class RunHistoryState: ObservableObject {
    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: String
        public let report: CaseRunReport
        /// Folder holding the screenshots of this run (`<runs folder>/<id>/`).
        public let evidenceDirectory: URL
        /// The folder the report was read from; evidence paths in the report are relative to it.
        public var rootDirectory: URL { evidenceDirectory.deletingLastPathComponent() }
        /// The report file itself.
        public var reportURL: URL { rootDirectory.appendingPathComponent("\(id).json") }

        public var key: String { report.testKey }
        public var title: String { report.title }
        public var startedAt: Date { report.startedAt }
        /// A run still marked RUNNING long after it started was killed before it could write its end: it is shown as INTERRUPTED, not as live.
        public var outcome: String {
            report.outcome == "RUNNING" && report.finishedAt == nil && Date().timeIntervalSince(report.startedAt) > Self.staleAfter ? "INTERRUPTED" : report.outcome
        }
        static let staleAfter: TimeInterval = 2 * 3600
        public var passed: Bool { report.outcome == "PASSED" }
        public var duration: TimeInterval? { report.finishedAt.map { $0.timeIntervalSince(report.startedAt) } }

        /// The report's actions grouped by the test step they belong to, in the shape the live run view uses.
        public var steps: [CaseRunState.Step] { Self.steps(of: report) }

        static func steps(of report: CaseRunReport) -> [CaseRunState.Step] {
            var order: [Int] = []
            var grouped: [Int: [CaseRunReport.Step]] = [:]
            for step in report.steps {
                if grouped[step.sourceStepNumber] == nil { order.append(step.sourceStepNumber) }
                grouped[step.sourceStepNumber, default: []].append(step)
            }
            return order.sorted().map { number in
                let rows = grouped[number] ?? []
                var step = CaseRunState.Step(id: number, text: rows.first?.intent ?? "Step \(number)")
                step.actions = rows.map {
                    CaseRunState.Action(id: $0.id, intent: $0.intent, status: CaseRunState.Status(report: $0.status), detail: $0.detail,
                                        evidence: $0.evidencePath ?? "")
                }
                step.status = CaseRunState.aggregate(step.actions.map(\.status))
                return step
            }
        }
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public var selectedID: String?

    public let directory: URL

    /// Where runs were saved before the folder was renamed. Read, never written.
    public let legacyDirectory: URL?

    /// `directory` is `.runs/cases`.
    public init(directory: URL, legacyDirectory: URL? = nil) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    public var selected: Entry? { entries.first { $0.id == selectedID } }

    /// True while the reports are being read.
    @Published public private(set) var isLoading = false

    /// Reads every readable report; files that do not decode are skipped. Keeps the selection when it still exists.
    public func reload() {
        apply(Self.read(directory: directory, legacyDirectory: legacyDirectory))
    }

    /// The same, with the reading done off the main thread: a few hundred reports would otherwise freeze the window while it opens.
    public func load() async {
        isLoading = true
        let directory = directory, legacy = legacyDirectory
        let found = await Task.detached(priority: .userInitiated) { Self.read(directory: directory, legacyDirectory: legacy) }.value
        apply(found)
        isLoading = false
    }

    private func apply(_ found: [Entry]) {
        entries = found
        if let selectedID, !entries.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    nonisolated private static func read(directory: URL, legacyDirectory: URL?) -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [String: Entry] = [:]
        for folder in (legacyDirectory.map { [$0] } ?? []) + [directory] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url), let report = try? decoder.decode(CaseRunReport.self, from: data) else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                found[id] = Entry(id: id, report: report, evidenceDirectory: folder.appendingPathComponent(id, isDirectory: true))
            }
        }
        return found.values.sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    }
}
