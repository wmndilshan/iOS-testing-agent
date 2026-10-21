import Foundation

public enum DeclarationKind: String, Codable, Sendable, CaseIterable {
    case `struct`, `class`, `enum`, actor, `protocol`, `extension`
    case initializer, deinitializer, method, function, property, `subscript`, enumCase, typeAlias, associatedType

    public var isType: Bool { [.struct, .class, .enum, .actor, .protocol].contains(self) }
    public var isNominalOrExtension: Bool { isType || self == .extension }
    /// Declarations with executable bodies that tests exercise directly.
    public var isCallable: Bool { [.initializer, .deinitializer, .method, .function, .subscript].contains(self) }
}

public enum AccessLevel: String, Codable, Sendable, Comparable {
    case `private`, `fileprivate`, `internal`, package, `public`, open

    private var rank: Int { [.private, .fileprivate, .internal, .package, .public, .open].firstIndex(of: self)! }
    public static func < (a: AccessLevel, b: AccessLevel) -> Bool { a.rank < b.rank }
    /// Visible outside its own file (a caller elsewhere can depend on it).
    public var isCrossFile: Bool { self >= .internal }
    public var isPublicAPI: Bool { self >= .public }
}

public struct Parameter: Codable, Hashable, Sendable {
    public var label: String?      // nil means `_`
    public var name: String
    public var type: String
    public var hasDefault: Bool
}

/// A name the declaration's body uses, as the parser sees it (no type checking).
///
/// `qualifier` is the receiver as written: a type name (`Foo.make()`), `self`, or a variable. `receiverType` is the
/// variable's statically declared type when the indexer could read it from a parameter, a local `let x: T` /
/// `let x = T(...)`, or a stored property of the enclosing type. Resolution against the index happens later.
public struct Reference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case call, member, type }
    public var name: String
    public var kind: Kind
    public var qualifier: String?
    public var receiverType: String?
    public var line: Int
}

/// Structural facts about an executable body. Only counts, names and fingerprints: never the source text.
public struct BodyFacts: Codable, Hashable, Sendable {
    public var ifCount = 0
    public var guardCount = 0
    public var switchCount = 0
    public var caseCount = 0
    public var loopCount = 0
    public var ternaryCount = 0
    public var throwCount = 0
    public var tryCount = 0
    public var catchCount = 0
    public var awaitCount = 0
    public var returnCount = 0
    /// `Task {}`, `Task.detached`, task groups, continuations, `MainActor.run`, `async let`, locks...
    public var concurrencyConstructs: [String] = []
    /// Type names of thrown values (`throw PlanError.x` -> `PlanError`).
    public var thrownTypes: [String] = []
    /// Properties assigned in the body (`state = ...`, `self.phase = ...`).
    public var assignedMembers: [String] = []
    /// Cases matched by `switch` / `case .x` patterns.
    public var matchedCases: [String] = []
    /// Freestanding macro uses (`#expect`, `#require`, ...) with counts.
    public var macroUses: [String: Int] = [:]
    /// `#expect(throws:)`, `#require(throws:)` and `XCTAssertThrowsError` uses.
    public var throwExpectations = 0
    public var references: [Reference] = []
    /// Normalized branch conditions (`guard x != nil`, `case .ready`), each at most 160 characters, in source order.
    /// Diffed between versions to find added and changed branches.
    public var branchConditions: [String] = []
    /// Hash of the control-flow skeleton (branch kinds and their normalized conditions).
    public var controlFlowFingerprint = ""
    /// Hash of all body tokens without trivia (comments and whitespace do not change it).
    public var bodyFingerprint = ""
    public var lineCount = 0

    public var branchCount: Int { ifCount + guardCount + caseCount + ternaryCount }
    public var referencedNames: Set<String> { Set(references.map(\.name)) }
}

public struct Declaration: Codable, Hashable, Sendable, Identifiable {
    public var id: SymbolID
    public var name: String
    public var kind: DeclarationKind
    public var module: String
    /// The enclosing type (or extension's extended type) symbol, if any.
    public var container: SymbolID?
    public var span: SourceSpan
    public var access: AccessLevel
    public var modifiers: [String]
    public var attributes: [String]
    public var isAsync: Bool
    public var isThrows: Bool
    public var typedThrows: String?
    public var isStatic: Bool
    public var parameters: [Parameter]
    public var returnType: String?
    public var genericParameters: [String]
    public var genericConstraints: [String]
    /// Inherited types / conformances (types and extensions). For properties, the declared type is `returnType`.
    public var inheritance: [String]
    /// The declaration header normalized to one line, without body or comments.
    public var signature: String
    public var body: BodyFacts?
    /// Enclosing extension's `where` / conformance context, for members declared in extensions.
    public var extensionContext: String?
    /// Argument text of `@Test` / `@Suite` attributes (display name, tags, traits), keyed by attribute name.
    public var attributeArguments: [String: String] = [:]

    /// Isolation-relevant markers: actor kind, global-actor attributes, `nonisolated`, `isolated`, `Sendable`.
    public var isolationMarkers: [String] {
        var out = attributes.filter { $0.hasSuffix("Actor") || $0 == "Sendable" || $0 == "preconcurrency" }
        out += modifiers.filter { ["nonisolated", "isolated", "sending", "consuming", "borrowing"].contains($0) }
        if kind == .actor { out.append("actor") }
        if inheritance.contains("Sendable") { out.append("Sendable") }
        return out.sorted()
    }
}
