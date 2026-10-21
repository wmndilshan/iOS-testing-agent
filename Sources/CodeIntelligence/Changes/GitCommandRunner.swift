import Foundation

/// The only process launch in CodeIntelligence: read-only `git` queries for change analysis.
///
/// - Subcommands are allow-listed (`rev-parse`, `diff`, `show`, `ls-files`); anything else throws before launch.
/// - Arguments are passed as an argv array, never through a shell.
/// - `GIT_OPTIONAL_LOCKS=0` stops `diff` from refreshing (writing) the index; external diff drivers and textconv are off.
/// - Output is bounded by a timeout; stderr is discarded (it can hold paths, never content we need).
struct GitCommandRunner: Sendable {
    static let allowedSubcommands: Set<String> = ["rev-parse", "diff", "show", "ls-files"]
    let workingDirectory: URL
    var timeout: TimeInterval = 30

    func run(_ subcommand: String, _ arguments: [String]) throws -> String {
        guard Self.allowedSubcommands.contains(subcommand) else { throw ChangeSourceError.disallowedGitCommand(subcommand) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotepath=off", "--no-pager", subcommand] + arguments
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment.filter { $0.key == "PATH" || $0.key == "HOME" || $0.key.hasPrefix("DEVELOPER_DIR") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else { throw ChangeSourceError.gitFailed(command: subcommand, status: process.terminationStatus) }
        return String(decoding: data, as: UTF8.self)
    }
}
