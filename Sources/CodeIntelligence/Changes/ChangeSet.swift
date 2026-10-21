import Foundation

public enum FileChangeStatus: String, Codable, Sendable {
    case added, modified, deleted, renamed
}

/// Raw input for one changed file, from any `ChangeSource`.
public struct RawFileChange: Sendable {
    public var path: String
    public var oldPath: String?
    public var status: FileChangeStatus
    public var oldText: String?
    public var newText: String?
    /// Changed line ranges in the new file (nil when the source cannot tell; the analyzer then uses declaration fingerprints only).
    public var changedLines: [ClosedRange<Int>]?
    /// Changed line ranges in the old file.
    public var removedLines: [ClosedRange<Int>]?

    public init(path: String, oldPath: String? = nil, status: FileChangeStatus, oldText: String?, newText: String?,
                changedLines: [ClosedRange<Int>]? = nil, removedLines: [ClosedRange<Int>]? = nil) {
        self.path = path; self.oldPath = oldPath; self.status = status; self.oldText = oldText; self.newText = newText
        self.changedLines = changedLines; self.removedLines = removedLines
    }
}

public struct FileChange: Codable, Hashable, Sendable {
    public var path: String
    public var oldPath: String?
    public var status: FileChangeStatus
    public var role: FileRole
    public var module: String
    public var changedLines: [ClosedRange<Int>]?
    public var addedLineCount: Int?
    public var removedLineCount: Int?
}

/// What about a declaration changed. Derived by comparing old and new `Declaration`s field by field.
public enum ChangeAspect: String, Codable, Sendable, CaseIterable, Comparable {
    case signature, parameters, returnType, access, throwing, async, isolation, concurrency, errorHandling, controlFlow
    case genericConstraints, conformance, attributes, stateMutation, body, declarationAdded, declarationRemoved

    public static func < (a: ChangeAspect, b: ChangeAspect) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

public enum SymbolChangeKind: String, Codable, Sendable { case added, removed, modified }

public struct SymbolChange: Codable, Hashable, Sendable {
    public var symbol: SymbolID
    public var kind: SymbolChangeKind
    public var aspects: [ChangeAspect]
    public var declarationKind: DeclarationKind
    public var file: String
    public var role: FileRole
    public var oldSignature: String?
    public var newSignature: String?
    /// The declaration is visible outside its file (`internal` or wider) before or after the change.
    public var isInterface: Bool
    public var isPublicAPI: Bool
    /// When a symbol's identity changed (renamed selector or overload), the ID it had before.
    public var previousSymbol: SymbolID?
    /// Branch conditions present only in the new / only in the old version (multiset difference).
    public var addedBranches: [String] = []
    public var removedBranches: [String] = []

    public var isSignatureChange: Bool { !Set(aspects).isDisjoint(with: [.signature, .parameters, .returnType, .access, .throwing, .async, .isolation, .genericConstraints]) }
}

/// The compact, deterministic description of a change. Never contains diff text or file contents.
public struct ChangeSet: Codable, Sendable {
    public var base: String
    public var files: [FileChange]
    public var symbols: [SymbolChange]
    /// Interface (cross-file) signature changes, the subset callers can observe.
    public var apiChanges: [SymbolID]
    /// Files the analyzer could not parse or read, with the reason.
    public var diagnostics: [String]

    public var productionSymbols: [SymbolChange] { symbols.filter { $0.role == .production } }
    public var isDocumentationOnly: Bool { !files.isEmpty && files.allSatisfy { $0.role == .documentation } }
    public var isTestOnly: Bool {
        !files.isEmpty && files.allSatisfy { [.test, .testSupport, .documentation].contains($0.role) } && files.contains { $0.role != .documentation }
    }
}
