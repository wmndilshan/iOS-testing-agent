import Foundation

/// A running test case: its output lines and a way to answer it. Output and input are text lines, nothing else.
public protocol CaseRunHandle: AnyObject, Sendable {
    /// Every line the run prints, in order. Finishes when the run ends.
    var lines: AsyncStream<String> { get }
    /// Writes one line to the run's input (an answer to a prompt).
    func send(_ line: String)
    func terminate()
}

/// Starts a test case run as its own process, so a crash or a hang in a run cannot take the app down.
public protocol CaseRunLaunching: Sendable {
    func launch(arguments: [String]) throws -> any CaseRunHandle
}
