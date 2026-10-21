import Foundation

/// What the person told the run to do differently: "use Test2 instead of Test1" (a substitution applied to every step from then on) and
/// anything else they said ("keep the Table view"), which is shown to the planner and the judge as a note.
struct RunGuidance: Codable, Equatable, Sendable {
    struct Substitution: Codable, Equatable, Sendable {
        let from: String
        let to: String
    }

    var substitutions: [Substitution] = []
    var notes: [String] = []

    var isEmpty: Bool { substitutions.isEmpty && notes.isEmpty }

    /// Adds what was just said. A later value for the same word replaces the earlier one, and "Test1 → Test2" followed by "Test2 → Test3"
    /// becomes "Test1 → Test3", so applying the list once is always right.
    mutating func merge(_ other: RunGuidance) {
        for new in other.substitutions {
            substitutions = substitutions.filter { $0.from != new.from }
            substitutions = substitutions.map { $0.to == new.from ? Substitution(from: $0.from, to: new.to) : $0 }
            if new.from != new.to, !substitutions.contains(where: { $0.from == $0.to }) { substitutions.append(new) }
        }
        for note in other.notes where !notes.contains(note) { notes.append(note) }
    }

    /// `text` with each word replaced, whole words only (Test1 does not change Test10), case as written.
    func apply(to text: String) -> String {
        var result = text
        for substitution in substitutions {
            let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: substitution.from) + "(?![A-Za-z0-9_])"
            result = result.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: substitution.to), options: .regularExpression)
        }
        return result
    }

    /// One line for the log and the report.
    var summary: String {
        (substitutions.map { "\($0.from) → \($0.to)" } + notes.map { "“\($0)”" }).joined(separator: "; ")
    }

    /// The block added to the planner's and the judge's prompts. Substitutions are already applied to the step text, so only the notes need saying.
    var promptBlock: String {
        var lines: [String] = []
        if !substitutions.isEmpty { lines.append("The person changed this test's data: " + substitutions.map { "use \($0.to) instead of \($0.from)" }.joined(separator: ", ") + ". The step text already shows the new values.") }
        if !notes.isEmpty { lines.append("The person also told you: " + notes.joined(separator: " ") + " This never overrides the step's expected result, and a destructive action still needs approval.") }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }
}

/// Reads a sentence the person typed into substitutions and notes, with no model call: the same words always mean the same thing.
enum GuidanceParser {
    private static let quote = #"["“”'`]?"#
    private static let patterns: [(String, from: Int, to: Int)] = [
        (#"^(?:please\s+)?(?:use\s+)?"# + quote + #"(.+?)"# + quote + #"\s+instead\s+of\s+"# + quote + #"(.+?)"# + quote + #"[.!]?$"#, 2, 1),
        (#"^(?:please\s+)?instead\s+of\s+"# + quote + #"(.+?)"# + quote + #",?\s+use\s+"# + quote + #"(.+?)"# + quote + #"[.!]?$"#, 1, 2),
        (#"^(?:please\s+)?replace\s+"# + quote + #"(.+?)"# + quote + #"\s+with\s+"# + quote + #"(.+?)"# + quote + #"[.!]?$"#, 1, 2),
        (#"^"# + quote + #"(.+?)"# + quote + #"\s*(?:→|->|=>)\s*"# + quote + #"(.+?)"# + quote + #"[.!]?$"#, 1, 2),
        (#"^"# + quote + #"([^\s=]+)"# + quote + #"\s*=\s*"# + quote + #"([^\s=]+)"# + quote + #"$"#, 1, 2)
    ]

    static func parse(_ text: String) -> RunGuidance {
        var result = RunGuidance()
        let clauses = text.replacingOccurrences(of: ";", with: "\n").split(whereSeparator: \.isNewline)
        for clause in clauses {
            let sentence = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }
            if let substitution = substitution(in: sentence) { result.merge(RunGuidance(substitutions: [substitution])) }
            else if isNoChange(sentence) { continue }
            else { result.merge(RunGuidance(notes: [String(sentence.prefix(300))])) }
        }
        return result
    }

    /// "use Test1 instead of Test1" says nothing: it is dropped, not kept as a note.
    private static func isNoChange(_ sentence: String) -> Bool {
        for (pattern, from, to) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)),
                  let fromRange = Range(match.range(at: from), in: sentence), let toRange = Range(match.range(at: to), in: sentence) else { continue }
            if sentence[fromRange].trimmingCharacters(in: .whitespaces) == sentence[toRange].trimmingCharacters(in: .whitespaces) { return true }
        }
        return false
    }

    private static func substitution(in sentence: String) -> RunGuidance.Substitution? {
        for (pattern, from, to) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)),
                  let fromRange = Range(match.range(at: from), in: sentence), let toRange = Range(match.range(at: to), in: sentence) else { continue }
            let old = String(sentence[fromRange]).trimmingCharacters(in: .whitespaces), new = String(sentence[toRange]).trimmingCharacters(in: .whitespaces)
            guard !old.isEmpty, !new.isEmpty, old != new, old.count <= 80, new.count <= 80 else { continue }
            return RunGuidance.Substitution(from: old, to: new)
        }
        return nil
    }
}

/// The guidance kept for a case until it is cleared: `.runs/guidance/<KEY>.json`.
struct GuidanceStore: Sendable {
    let directory: URL

    private func file(_ key: String) -> URL {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).json")
    }

    func load(_ key: String) -> RunGuidance {
        (try? Data(contentsOf: file(key))).flatMap { try? JSONDecoder().decode(RunGuidance.self, from: $0) } ?? RunGuidance()
    }

    func save(_ guidance: RunGuidance, for key: String) {
        guard !guidance.isEmpty else { clear(key); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(guidance).write(to: file(key), options: .atomic)
    }

    func clear(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }
}
