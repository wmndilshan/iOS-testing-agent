import Foundation

/// Persistent history of finished runs (summaries plus full redacted traces).
///
/// Read-only from the point of view of execution: `replayRequest` only describes what a *new*
/// run would need; starting it still traverses the trusted spine. `RunHistoryStore` is the
/// file-backed implementation; its directory is chosen by `AppCompositionRoot`.
public protocol RunHistoryStoring: Sendable {
    func save(record: RunHistoryRecord, trace: RunTrace?) async throws
    func list() async -> [RunHistoryRecord]
    func loadTrace(runID: String) async -> RunTrace?
    func replayRequest(for runID: String) async -> ReplayRequest?
}
