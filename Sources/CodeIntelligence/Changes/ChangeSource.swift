import Foundation

/// Produces the raw file changes to analyze. Implementations: git (`HEAD` vs working tree), a baseline snapshot
/// directory, or an explicit file list.
public protocol ChangeSource: Sendable {
    var baseDescription: String { get }
    func changes() throws -> [RawFileChange]
}

public enum ChangeSourceError: Error, Equatable, CustomStringConvertible {
    case notAGitRepository(String)
    case gitFailed(command: String, status: Int32)
    case invalidRevision(String)
    case disallowedGitCommand(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .notAGitRepository(let p): "\(p) is not inside a git work tree; use --baseline-dir or --files"
        case .gitFailed(let c, let s): "git \(c) failed with status \(s)"
        case .invalidRevision(let r): "invalid revision '\(r)'"
        case .disallowedGitCommand(let c): "git subcommand '\(c)' is not in the read-only allow-list"
        case .unreadable(let p): "cannot read \(p)"
        }
    }
}

/// Compares the working tree against a baseline copy of the repository (for trees without git, and for tests).
/// Swift and Markdown files are compared; build output and run data are excluded by the scanner rules.
public struct SnapshotChangeSource: ChangeSource {
    public let root: URL
    public let baseline: URL
    public var baseDescription: String { "snapshot:\(baseline.path)" }

    public init(root: URL, baseline: URL) { self.root = root; self.baseline = baseline }

    public func changes() throws -> [RawFileChange] {
        let now = listing(RepositoryScanner(root: root))
        let before = listing(RepositoryScanner(root: baseline))
        var out: [RawFileChange] = []
        for path in Set(now.keys).union(before.keys).sorted() {
            switch (before[path], now[path]) {
            case (nil, let new?): out.append(RawFileChange(path: path, status: .added, oldText: nil, newText: new))
            case (let old?, nil): out.append(RawFileChange(path: path, status: .deleted, oldText: old, newText: nil))
            case (let old?, let new?) where old != new:
                out.append(RawFileChange(path: path, status: .modified, oldText: old, newText: new, changedLines: LineDiff.changedLines(old: old, new: new)))
            default: break
            }
        }
        return out
    }

    private func listing(_ scanner: RepositoryScanner) -> [String: String] {
        var out: [String: String] = [:]
        for p in scanner.swiftFiles() + scanner.markdownFiles() {
            out[p] = try? String(contentsOf: scanner.root.appendingPathComponent(p), encoding: .utf8)
        }
        return out
    }
}

/// Treats the given files as modified with unknown baseline: every declaration in them counts as changed.
public struct ExplicitFilesChangeSource: ChangeSource {
    public let root: URL
    public let paths: [String]
    public var baseDescription: String { "explicit-files" }

    public init(root: URL, paths: [String]) { self.root = root; self.paths = paths }

    public func changes() throws -> [RawFileChange] {
        try paths.sorted().map { p in
            guard let text = try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) else { throw ChangeSourceError.unreadable(p) }
            return RawFileChange(path: p, status: .modified, oldText: nil, newText: text)
        }
    }
}

/// Minimal line diff (LCS over line hashes) for sources that do not provide hunks. Bounded: for very large files it
/// falls back to marking the differing middle region between the common prefix and suffix.
enum LineDiff {
    static func changedLines(old: String, new: String) -> [ClosedRange<Int>] {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])
        if midB.isEmpty { return midA.isEmpty ? [] : [max(1, prefix)...max(1, prefix)] }
        guard midA.count * midB.count <= 4_000_000 else { return [(prefix + 1)...(prefix + midB.count)] }
        // LCS table over the middle region; lines of B not in the LCS are changed.
        var dp = Array(repeating: Array(repeating: 0, count: midB.count + 1), count: midA.count + 1)
        for i in stride(from: midA.count - 1, through: 0, by: -1) {
            for j in stride(from: midB.count - 1, through: 0, by: -1) {
                dp[i][j] = midA[i] == midB[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var changed: [Int] = []
        var i = 0, j = 0
        var deletionAt: [Int] = []
        while j < midB.count {
            if i < midA.count, midA[i] == midB[j] { i += 1; j += 1 } else if i < midA.count, dp[i + 1][j] >= dp[i][j + 1] {
                deletionAt.append(prefix + j + 1); i += 1
            } else { changed.append(prefix + j + 1); j += 1 }
        }
        if i < midA.count { deletionAt.append(prefix + midB.count) }
        return ranges(from: Set(changed + deletionAt.map { max(1, $0) }))
    }

    static func ranges(from lines: Set<Int>) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for l in lines.sorted() {
            if let last = out.last, last.upperBound + 1 == l { out[out.count - 1] = last.lowerBound...l } else { out.append(l...l) }
        }
        return out
    }
}
