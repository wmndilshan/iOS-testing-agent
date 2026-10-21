import Foundation
import AgentCore

public enum CodeTokenKind: Sendable, Equatable {
    case plain, keyword, string, comment, number, type, key, attribute
}

public struct CodeToken: Sendable, Equatable {
    public let kind: CodeTokenKind
    public let text: String
}

/// A small, dependency-free tokenizer for the code a model puts in a chat: enough to colour keywords, strings, comments, numbers and types in the
/// languages that show up here. It never fails: unknown languages and very long input come back as plain text.
public enum SyntaxHighlighter {
    private struct Grammar {
        var keywords: Set<String>
        var lineComments: [String] = ["//"]
        var blockComment: (String, String)? = ("/*", "*/")
        var quotes: [Character] = ["\"", "'"]
        var tripleQuotes = false
        var typesByCapital = true
    }

    private static let cLike = Set("if else for while do switch case default break continue return in is as try catch throw throws finally new delete this super null nil true false void static final const let var func function class struct enum protocol extension interface import export from package public private internal protected open override init self Self async await guard where defer typealias associatedtype some any inout lazy weak unowned mutating fileprivate fun val when object def lambda yield with".split(separator: " ").map(String.init))
    private static let python = Set("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield None True False self".split(separator: " ").map(String.init))
    private static let shell = Set("if then else elif fi for while do done case esac in function return export local echo cd ls cat grep sed awk git swift xcodebuild xcrun curl rm mv cp mkdir exit set unset source".split(separator: " ").map(String.init))
    private static let json = Set(["true", "false", "null"])

    private static func grammar(for language: String) -> Grammar? {
        switch language.lowercased() {
        case "swift", "kotlin", "kt", "java", "c", "cpp", "c++", "objc", "objective-c", "m", "cs", "csharp", "go", "rust", "rs", "dart":
            return Grammar(keywords: cLike, tripleQuotes: true)
        case "js", "javascript", "jsx", "ts", "typescript", "tsx":
            return Grammar(keywords: cLike, quotes: ["\"", "'", "`"])
        case "python", "py":
            return Grammar(keywords: python, lineComments: ["#"], blockComment: nil, tripleQuotes: true)
        case "bash", "sh", "zsh", "shell", "console":
            return Grammar(keywords: shell, lineComments: ["#"], blockComment: nil, typesByCapital: false)
        case "json", "jsonc":
            return Grammar(keywords: json, lineComments: [], blockComment: nil, quotes: ["\""], typesByCapital: false)
        case "yaml", "yml", "toml":
            return Grammar(keywords: json, lineComments: ["#"], blockComment: nil, typesByCapital: false)
        default:
            return nil
        }
    }

    public static let maxCharacters = 20_000

    public static func tokens(_ code: String, language: String) -> [CodeToken] {
        guard code.count <= maxCharacters, let grammar = grammar(for: language) else { return [CodeToken(kind: .plain, text: code)] }
        let isJSON = ["json", "jsonc"].contains(language.lowercased())
        let chars = Array(code)
        var tokens: [CodeToken] = []
        var plain = ""
        func flush() { if !plain.isEmpty { tokens.append(CodeToken(kind: .plain, text: plain)); plain = "" } }
        func emit(_ kind: CodeTokenKind, _ text: String) { flush(); tokens.append(CodeToken(kind: kind, text: text)) }
        func has(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix)
            return index + p.count <= chars.count && Array(chars[index..<index + p.count]) == p
        }
        func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let marker = grammar.lineComments.first(where: { has($0, at: i) }) {
                var j = i + marker.count
                while j < chars.count, chars[j] != "\n" { j += 1 }
                emit(.comment, String(chars[i..<j])); i = j
            } else if let block = grammar.blockComment, has(block.0, at: i) {
                var j = i + block.0.count
                while j < chars.count, !has(block.1, at: j) { j += 1 }
                j = min(chars.count, j + block.1.count)
                emit(.comment, String(chars[i..<j])); i = j
            } else if grammar.tripleQuotes, has("\"\"\"", at: i) || has("'''", at: i) {
                let fence = String(chars[i..<i + 3])
                var j = i + 3
                while j < chars.count, !has(fence, at: j) { j += 1 }
                j = min(chars.count, j + 3)
                emit(.string, String(chars[i..<j])); i = j
            } else if grammar.quotes.contains(c) {
                var j = i + 1
                while j < chars.count, chars[j] != c, chars[j] != "\n" || c == "`" { j += chars[j] == "\\" ? 2 : 1 }
                j = min(chars.count, j + 1)
                let text = String(chars[i..<j])
                // In JSON, a string followed by a colon is a key.
                var k = j
                while isJSON, k < chars.count, chars[k] == " " { k += 1 }
                emit(isJSON && k < chars.count && chars[k] == ":" ? .key : .string, text); i = j
            } else if c.isNumber, i == 0 || !isIdentifier(chars[i - 1]) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j].isHexDigit || chars[j] == "x" { j += 1 }
                emit(.number, String(chars[i..<j])); i = j
            } else if c == "@" || c == "$" || c == "#", i + 1 < chars.count, isIdentifierStart(chars[i + 1]), !(c == "#" && grammar.lineComments.contains("#")) {
                var j = i + 1
                while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                emit(.attribute, String(chars[i..<j])); i = j
            } else if c == "$", grammar.lineComments.contains("#"), i + 1 < chars.count, isIdentifierStart(chars[i + 1]) {
                var j = i + 1
                while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                emit(.attribute, String(chars[i..<j])); i = j
            } else if isIdentifierStart(c) {
                var j = i
                while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                if grammar.keywords.contains(word) { emit(.keyword, word) }
                else if grammar.typesByCapital, c.isUppercase { emit(.type, word) }
                else { plain += word }
                i = j
            } else {
                plain.append(c); i += 1
            }
        }
        flush()
        // Neighbouring pieces of the same kind read as one.
        var merged: [CodeToken] = []
        for token in tokens {
            if let last = merged.last, last.kind == token.kind { merged[merged.count - 1] = CodeToken(kind: token.kind, text: last.text + token.text) }
            else { merged.append(token) }
        }
        return merged
    }
}
