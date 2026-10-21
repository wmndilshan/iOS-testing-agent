import Foundation

/// Owns the bookkeeping that closes a run: emit the terminal event exactly once and hand the finished trace to the history sink.
///
/// It is a passive collaborator of `ScenarioExecutionController`. It cannot approve, dispatch or execute anything and it never chooses
/// where run data lives: the finished-run sink is injected (see `AppCompositionRoot`).
struct RunLifecycleCoordinator {
    var onRunFinished: ((RunTrace) -> Void)?

    private var finishedEmitted = false

    /// Called when a new run starts, so the run can be finished again.
    mutating func beginRun() {
        finishedEmitted = false
    }

    /// Emits the run's terminal event exactly once and notifies the sink. Later calls for the same run are no-ops.
    mutating func finish(trace: inout RunTrace?, stepID: String?, result: String) {
        guard !finishedEmitted else { return }
        finishedEmitted = true
        trace?.append(eventType: .runFinished, stepID: stepID, result: result)
        trace?.finish()
        if let trace { onRunFinished?(trace) }
    }
}
