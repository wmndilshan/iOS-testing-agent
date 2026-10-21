import Foundation

/// `base` (default `HEAD`) versus the working tree, including staged, unstaged and untracked (non-ignored) files.
/// Paths are relative to `root`, which may be a subdirectory of the work tree.
public struct GitChangeSource: ChangeSource {
    public let root: URL
    public let base: String
    public var baseDescription: String { "git:\(base)" }

    public init(root: URL, base: String = "HEAD") { self.root = root; self.base = base }

    static func isValidRevision(_ r: String) -> Bool {
        r.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/~^@{}-]{0,199}$"#, options: .regularExpression) != nil && !r.contains("..")
    }

    public func changes() throws -> [RawFileChange] {
        guard Self.isValidRevision(base) else { throw ChangeSourceError.invalidRevision(base) }
        let git = GitCommandRunner(workingDirectory: root)
        do { _ = try git.run("rev-parse", ["--show-toplevel"]) } catch { throw ChangeSourceError.notAGitRepository(root.path) }

        let nameStatus = try git.run("diff", ["--no-ext-diff", "--no-textconv", "--relative", "--name-status", "-M", base])
        let hunks = UnifiedDiffParser.parse(try git.run("diff", ["--no-ext-diff", "--no-textconv", "--relative", "-U0", "-M", base]))
        var out: [RawFileChange] = []
        for line in nameStatus.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard let code = fields.first?.first, fields.count >= 2 else { continue }
            let path = fields.last!
            let oldPath = code == "R" ? fields[1] : nil
            let status: FileChangeStatus = switch code {
            case "A": .added
            case "D": .deleted
            case "R": .renamed
            default: .modified
            }
            let old = status == .added ? nil : try? git.run("show", ["\(base):./\(oldPath ?? path)"])
            let new = status == .deleted ? nil : try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let h = hunks[path] ?? hunks[oldPath ?? ""]
            out.append(RawFileChange(path: path, oldPath: oldPath, status: status, oldText: old, newText: new,
                                     changedLines: h?.added ?? (status == .renamed ? [] : nil), removedLines: h?.removed))
        }
        let untracked = try git.run("ls-files", ["--others", "--exclude-standard"])
        for path in untracked.split(separator: "\n").map(String.init) where !out.contains(where: { $0.path == path }) {
            let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            out.append(RawFileChange(path: path, status: .added, oldText: nil, newText: text))
        }
        return out.sorted { $0.path < $1.path }
    }
}

/// Parses `git diff -U0` output into changed line ranges per file. Only hunk headers are read; diff text is discarded.
enum UnifiedDiffParser {
    struct FileHunks: Equatable {
        var added: [ClosedRange<Int>] = []
        var removed: [ClosedRange<Int>] = []
    }

    static func parse(_ diff: String) -> [String: FileHunks] {
        var out: [String: FileHunks] = [:]
        var oldPath: String?
        var current: String?
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--- ") {
                oldPath = path(String(line.dropFirst(4)))
            } else if line.hasPrefix("+++ ") {
                current = path(String(line.dropFirst(4))) ?? oldPath
            } else if line.hasPrefix("@@"), let file = current, let (old, new) = header(String(line)) {
                if let old { out[file, default: FileHunks()].removed.append(old) }
                if let new { out[file, default: FileHunks()].added.append(new) }
            }
        }
        return out
    }

    private static func path(_ s: String) -> String? {
        if s == "/dev/null" { return nil }
        return s.hasPrefix("a/") || s.hasPrefix("b/") ? String(s.dropFirst(2)) : s
    }

    /// `@@ -12,3 +14,0 @@` -> (12...14, nil). A count of 0 means no lines on that side.
    static func header(_ line: String) -> (ClosedRange<Int>?, ClosedRange<Int>?)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> ClosedRange<Int>? {
            let nums = s.dropFirst().split(separator: ",").compactMap { Int($0) }
            guard let start = nums.first else { return nil }
            let count = nums.count > 1 ? nums[1] : 1
            return count == 0 ? nil : start...(start + count - 1)
        }
        return (range(parts[1]), range(parts[2]))
    }
}
