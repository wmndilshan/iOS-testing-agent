import Foundation

/// A driver that can bring the app under test to the front, starting it if it is not running. A running app keeps its state: this never
/// restarts it. Used before a failed step is retried and when a run resumes in the middle of a case.
public protocol AppForegrounding: Sendable {
    func bringToForeground(bundleID: String) async
}
