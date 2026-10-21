import Foundation

/// What a run learns from the app's source when a step cannot find its way: where the words of the step live in the code, the code around
/// them (the view, its actions, what it presents) and which files show it. It reads only, through the same repository index the agents use.
struct CodeGuide: Sendable {
    let knowledge: RepoKnowledge

    /// One place in the source that matches the step.
    struct Evidence: Equatable, Sendable {
        let file: String
        let line: Int
        let typeName: String?
        let matched: [String]
        let snippet: [String]
        /// Where the type is used: usually the screen or action that leads to it.
        let usedFrom: [String]
    }

    static let maxFiles = 3
    static let snippetBefore = 6
    static let snippetAfter = 14
    static let maxCharacters = 2400

    init(root: URL, projectRoot: URL) {
        knowledge = RepoKnowledge(sandbox: RepoSandbox(root: root), projectRoot: projectRoot)
    }

    init(knowledge: RepoKnowledge) { self.knowledge = knowledge }

    func prewarm() { knowledge.prewarm() }

    /// The facts block for the planner, or nil when the source says nothing about this step.
    func facts(stepText: String, expected: String, failure: String?, screenLabels: [String]) -> String? {
        let terms = CodeTerms.extract(from: [stepText, expected, failure ?? ""])
        guard !terms.isEmpty else { return nil }
        let found = evidence(for: terms)
        return found.isEmpty ? nil : Self.format(found)
    }

    func evidence(for terms: [String]) -> [Evidence] {
        // path -> (terms that matched in it, lines where they did)
        var byFile: [String: (terms: [String], lines: [Int])] = [:]
        for term in terms {
            for hit in knowledge.search(term, limit: 14, perFile: 2) {
                guard let (path, line) = Self.location(of: hit), path.hasSuffix(".swift"), !RepoKnowledge.isNoise(path) else { continue }
                var entry = byFile[path] ?? ([], [])
                if !entry.terms.contains(term) { entry.terms.append(term) }
                entry.lines.append(line)
                byFile[path] = entry
            }
        }
        // Files that match the most distinct terms come first: one file holding the identifier and the label is the screen itself.
        let ranked = byFile.sorted { ($0.value.terms.count, $1.key) > ($1.value.terms.count, $0.key) }.prefix(Self.maxFiles)
        let files = Dictionary(uniqueKeysWithValues: knowledge.textFiles().map { ($0.path, $0.lines) })
        return ranked.compactMap { path, entry in
            guard let lines = files[path], let line = entry.lines.min(), line >= 1, line <= lines.count else { return nil }
            let start = max(0, line - 1 - Self.snippetBefore), end = min(lines.count, line + Self.snippetAfter)
            let snippet = lines[start..<end].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let type = Self.typeName(in: lines)
            return Evidence(file: path, line: line, typeName: type, matched: entry.terms, snippet: snippet, usedFrom: type.map { usedFrom($0, excluding: path) } ?? [])
        }
    }

    private func usedFrom(_ type: String, excluding path: String) -> [String] {
        knowledge.search(type, limit: 12, perFile: 1).filter { !$0.hasPrefix(path + ":") && $0.contains(".swift:") && !RepoKnowledge.isNoise($0) }.prefix(3).map { String($0.prefix(140)) }
    }

    static func location(of hit: String) -> (path: String, line: Int)? {
        let parts = hit.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let line = Int(parts[1]) else { return nil }
        return (String(parts[0]), line)
    }

    private static let declaration = try! NSRegularExpression(pattern: #"^\s*(?:public |internal |private |fileprivate |final )*(?:struct|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#)

    static func typeName(in lines: [String]) -> String? {
        for line in lines {
            if let m = declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 1), in: line) { return String(line[r]) }
        }
        return nil
    }

    /// The block the planner reads: short, with places and code, nothing it has to interpret about the repository's layout.
    static func format(_ evidence: [Evidence]) -> String {
        var out = "Facts from the app's source code (read-only). Use them to decide how to reach or operate this UI; labels and identifiers still must come from the live screen:\n"
        for item in evidence {
            out += "- \(item.file):\(item.line)" + (item.typeName.map { " (\($0))" } ?? "") + " matches " + item.matched.map { "'\($0)'" }.joined(separator: ", ") + "\n"
            out += item.snippet.map { "    " + $0.prefix(150) }.joined(separator: "\n") + "\n"
            if !item.usedFrom.isEmpty { out += "  used from: " + item.usedFrom.joined(separator: " | ") + "\n" }
            if out.count >= maxCharacters { break }
        }
        return String(out.prefix(maxCharacters))
    }
}
