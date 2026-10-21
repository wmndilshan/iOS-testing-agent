import Foundation
import AgentCore

/// Launches the `AutonomousTestingAgent` command line tool for one test case. Arguments are an array, never a shell string.
public struct CaseRunProcessLauncher: CaseRunLaunching {
    private let executable: URL
    private let workingDirectory: URL

    public init(executable: URL, workingDirectory: URL) {
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    public func launch(arguments: [String]) throws -> any CaseRunHandle {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: executable.path, NSLocalizedDescriptionKey: "The test runner was not found at \(executable.path). Build it with `swift build`."])
        }
        return try CaseRunProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
    }
}

final class CaseRunProcess: CaseRunHandle, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let process = Process()
    private let input = Pipe()

    init(executable: URL, arguments: [String], workingDirectory: URL) throws {
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream { continuation = $0 }
        let sink = continuation!
        let reader = output.fileHandleForReading
        try process.run()
        Thread.detachNewThread {
            var pending = Data()
            var finished = false
            while !finished {
                // A pool per read: this thread never returns to a run loop, so without one every chunk read stays allocated until the run ends.
                autoreleasepool {
                    let chunk = reader.availableData
                    if chunk.isEmpty { finished = true; return }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        sink.yield(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
            }
            if !pending.isEmpty { sink.yield(String(decoding: pending, as: UTF8.self)) }
            sink.finish()
        }
    }

    func send(_ line: String) {
        guard process.isRunning, let data = (line + "\n").data(using: .utf8) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    deinit { terminate() }
}
