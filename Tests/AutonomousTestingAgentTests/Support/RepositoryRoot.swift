import Foundation

/// Locates the repository root by walking up to Package.swift, so tests that inspect the real
/// `.skills/` / `.runs/` directories or the source tree don't depend on how deeply they are nested.
enum RepositoryRoot {
    static let url: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }()
}
