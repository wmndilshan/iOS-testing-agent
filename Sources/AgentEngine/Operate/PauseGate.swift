import Foundation

/// Lets a run be paused between steps without losing anything: the work waits at the next safe point (between graph nodes, between model turns,
/// before a tool call) and carries on when resumed. Stop ends the run at the same points.
actor PauseGate {
    private(set) var isPaused = false
    private(set) var isStopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var resumed = false

    func pause() { if !isStopped { isPaused = true } }

    /// True once after a resume: the person may have used the device meanwhile, so what the graph last read can no longer be trusted.
    func takeResumed() -> Bool { defer { resumed = false }; return resumed }

    func resume() {
        if isPaused { resumed = true }
        isPaused = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    /// Ends the run; anything waiting is released so it can see the stop.
    func stop() {
        isStopped = true
        resume()
    }

    /// A new task starts: nothing is paused or stopped any more.
    func reset() {
        isStopped = false
        isPaused = false
    }

    /// Returns at once when running; waits while paused. Check `isStopped` afterwards.
    func checkpoint() async {
        while isPaused && !isStopped {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
