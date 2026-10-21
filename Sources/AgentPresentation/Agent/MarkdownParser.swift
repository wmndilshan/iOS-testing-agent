import Foundation
import AgentCore

/// A block of a markdown document. Inline styling (bold, italic, code, links) is handled per block by `AttributedString`.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(indent: Int, marker: String, text: String)
    /// A checklist item: `- [ ] todo` or `- [x] done`.
    case task(indent: Int, done: Bool, text: String)
    case code(language: String, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

public enum MarkdownParser {
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^(\s*)([-*+•])\s+(.*)$"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^(\s*)(\d+[.)])\s+(.*)$"#)

    private static func groups(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.allSatisfy { "|-: ".contains($0) } && t.contains("|")
    }

    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(lines[index]); index += 1 }
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if let g = groups(heading, trimmed) {
                flushParagraph()
                blocks.append(.heading(level: g[0].count, text: g[1]))
            } else if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), Set(trimmed).count == 1 {
                flushParagraph()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[index])); index += 1 }
                blocks.append(.table(header: header, rows: rows))
                continue
            } else if let g = groups(bullet, line) {
                flushParagraph()
                let item = g[2]
                if item.hasPrefix("[ ] ") || item.hasPrefix("[x] ") || item.hasPrefix("[X] ") {
                    blocks.append(.task(indent: g[0].count / 2, done: !item.hasPrefix("[ ] "), text: String(item.dropFirst(4))))
                } else {
                    blocks.append(.listItem(indent: g[0].count / 2, marker: "•", text: item))
                }
            } else if let g = groups(numbered, line) {
                flushParagraph()
                blocks.append(.listItem(indent: g[0].count / 2, marker: g[1], text: g[2]))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }
}

