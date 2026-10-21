import Foundation
import CryptoKit

/// Stable identity of a declaration: `Module.Type.member(label:label:)`.
///
/// Built only from the declaration's module, lexical container and signature, never from its position, so the
/// same symbol has the same ID before and after an edit that moves it. Overloads that share labels are
/// disambiguated with their parameter types (`Module.T.f(_:)[Int]`). Extensions are `Module.T{extension:P,Q}`.
public struct SymbolID: RawRepresentable, Codable, CodingKeyRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public static func < (a: SymbolID, b: SymbolID) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// The last path component without module or container, e.g. `dispatch(_:)` for `M.T.dispatch(_:)`.
    public var leaf: String {
        // Selector parentheses may contain dots only inside type disambiguators, which follow the selector.
        let head = rawValue.split(separator: "(", maxSplits: 1).first.map(String.init) ?? rawValue
        let tail = rawValue.dropFirst(head.count)
        return (head.split(separator: ".").last.map(String.init) ?? head) + tail
    }
}

/// A source range. Lines and columns are 1-based, as reported by SwiftSyntax.
public struct SourceSpan: Codable, Hashable, Sendable, CustomStringConvertible {
    public var file: String
    public var line: Int
    public var column: Int
    public var endLine: Int
    public var endColumn: Int

    public init(file: String, line: Int, column: Int, endLine: Int, endColumn: Int) {
        self.file = file; self.line = line; self.column = column; self.endLine = endLine; self.endColumn = endColumn
    }

    public var lines: ClosedRange<Int> { line...max(line, endLine) }
    public var description: String { "\(file):\(line):\(column)-\(endLine):\(endColumn)" }

    public func overlaps(_ ranges: [ClosedRange<Int>]) -> Bool { ranges.contains { $0.overlaps(lines) } }
}

enum Fingerprint {
    /// Short, stable (cross-process) content hash. `Hasher` is seeded per process and cannot be used here.
    static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
