import Foundation

/// The process working directory, the default project root for CLI runs.
public enum WorkingDirectory {
    public static var url: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
}
