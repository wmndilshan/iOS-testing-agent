import Foundation

public enum FileRole: String, Codable, Sendable {
    case production, test, testSupport, documentation, other
}

/// Per-file structural facts. Holds declarations' IDs and a content hash; never the file's text.
public struct FileFacts: Codable, Hashable, Sendable {
    public var path: String            // repository-relative
    public var module: String          // SwiftPM target, from the Sources/<T> or Tests/<T> folder
    public var role: FileRole
    public var imports: [String]
    public var declarations: [SymbolID]
    public var contentHash: String
    public var lineCount: Int
    /// Number of parser diagnostics. A file with errors is still indexed, but facts may be incomplete.
    public var parseErrorCount: Int
}

/// The deterministic AST index: files, declarations and their structural facts.
public struct ASTIndex: Sendable {
    public private(set) var files: [String: FileFacts] = [:]
    public private(set) var declarations: [SymbolID: Declaration] = [:]
    /// Container -> member IDs (sorted), maintained on `add`.
    private var memberIDs: [SymbolID: [SymbolID]] = [:]

    public init() {}

    public mutating func add(file: FileFacts, declarations decls: [Declaration]) {
        if let old = files[file.path] {
            for id in old.declarations {
                if let c = declarations[id]?.container { memberIDs[c]?.removeAll { $0 == id } }
                declarations[id] = nil
            }
        }
        files[file.path] = file
        for d in decls {
            declarations[d.id] = d
            if let c = d.container {
                memberIDs[c, default: []].append(d.id)
                memberIDs[c]!.sort()
            }
        }
    }

    public subscript(_ id: SymbolID) -> Declaration? { declarations[id] }

    public func symbols(inFile path: String) -> [Declaration] {
        (files[path]?.declarations ?? []).compactMap { declarations[$0] }
    }

    /// Members of a type, including members declared in its extensions (any file, same module).
    public func members(of type: SymbolID) -> [Declaration] {
        (memberIDs[type] ?? []).compactMap { declarations[$0] }
    }

    /// Types and extensions that list `protocolName` in their inheritance clause.
    public func conformances(to protocolName: String) -> [Declaration] {
        declarations.values.filter { $0.kind.isNominalOrExtension && $0.inheritance.contains(protocolName) }.sorted { $0.id < $1.id }
    }

    public var productionFiles: [FileFacts] { files.values.filter { $0.role == .production }.sorted { $0.path < $1.path } }
    public var testFiles: [FileFacts] { files.values.filter { $0.role == .test || $0.role == .testSupport }.sorted { $0.path < $1.path } }

    public func role(of id: SymbolID) -> FileRole? { declarations[id].flatMap { files[$0.span.file]?.role } }
}
