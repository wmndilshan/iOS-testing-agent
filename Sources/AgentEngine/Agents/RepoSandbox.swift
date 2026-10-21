import Foundation

/// Read-only access to the repository the agents study. There is no write API: a path outside the root, a secret, or a big file is refused.
struct RepoSandbox: Sendable {
    struct Refused: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    let root: URL
    private let maxFileBytes = 200_000
    private static let blockedNames: Set<String> = [".env", ".git", ".build", ".ssh", "id_rsa", "id_ed25519", ".netrc", ".npmrc", ".pypirc"]
    private static let blockedExtensions: Set<String> = ["pem", "key", "p12", "keychain", "mobileprovision", "p8"]

    init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// The real location of a repository-relative path, or why it may not be read.
    func resolve(_ relative: String) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { throw Refused(reason: "Paths are relative to the repository root.") }
        let url = (trimmed.isEmpty || trimmed == "." ? root : root.appendingPathComponent(trimmed)).resolvingSymlinksInPath().standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw Refused(reason: "\(relative) is outside the repository.") }
        let parts = url.path.dropFirst(root.path.count).split(separator: "/").map(String.init)
        if let hit = parts.first(where: { Self.blockedNames.contains($0) || $0.hasPrefix(".env") }) { throw Refused(reason: "\(hit) is not readable by agents.") }
        if Self.blockedExtensions.contains(url.pathExtension.lowercased()) { throw Refused(reason: "\(url.lastPathComponent) looks like a key or certificate.") }
        return url
    }

    func relativePath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root.path ? "." : String(path.dropFirst(root.path.count + 1))
    }

    func list(_ relative: String) throws -> [String] {
        let url = try resolve(relative)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        return names.compactMap { name in
            guard !Self.blockedNames.contains(name), !name.hasPrefix(".env"), name != ".DS_Store" else { return nil }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }
    }

    /// A text file, optionally a line window. Binary or oversized files are refused.
    func read(_ relative: String, from: Int? = nil, to: Int? = nil) throws -> String {
        let url = try resolve(relative)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxFileBytes else { throw Refused(reason: "\(relative) is \(size) bytes; read a line window with from/to or use search_text.") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Refused(reason: "\(relative) is not a UTF-8 text file.") }
        guard from != nil || to != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        let start = max((from ?? 1), 1), end = min(to ?? lines.count, lines.count)
        guard start <= end else { return "" }
        return lines[(start - 1)..<end].enumerated().map { "\(start + $0.offset): \($0.element)" }.joined(separator: "\n")
    }

    /// Lines containing `query` (case-insensitive) in readable text files under a folder, as `path:line: text`.
    func search(_ query: String, in relative: String = ".", limit: Int = 60) throws -> [String] {
        let base = try resolve(relative)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return [] }
        var hits: [String] = []
        let needle = query.lowercased()
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory == true
            if name.hasPrefix(".") || ["DerivedData", "node_modules", "Pods", "Carthage"].contains(name) {
                // skipDescendants is for folders only: on a file it ends the walk of the whole folder.
                if isDirectory { walker.skipDescendants() }
                continue
            }
            if isDirectory { continue }
            guard (values?.fileSize ?? 0) <= maxFileBytes, (try? resolve(relativePath(url))) != nil,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() where line.lowercased().contains(needle) {
                hits.append("\(relativePath(url)):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(160))")
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }
}
