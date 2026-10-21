import Foundation

/// Reference edges between indexed declarations, resolved from the AST's `Reference`s.
///
/// Resolution is name-based over parsed identifiers (no type checker), narrowed by the receiver: implicit `self`, a type
/// qualifier, a parameter/local with a written type, or a stored property of the enclosing type. An edge is `strong`
/// when narrowing leaves exactly the members of one type (or a unique name); otherwise it is `weak` and carries the
/// candidate count. Names with too many candidates are dropped and counted, never linked to everything.
public struct SymbolGraph: Sendable {
    public enum Strength: String, Codable, Sendable, Comparable {
        case weak, strong
        public static func < (a: Strength, b: Strength) -> Bool { a == .weak && b == .strong }
    }
    public enum Relation: String, Codable, Sendable { case references, calls, constructs, implements, conforms, extends }

    public struct Edge: Codable, Hashable, Sendable {
        public var from: SymbolID
        public var to: SymbolID
        public var relation: Relation
        public var strength: Strength
        public var line: Int?
    }

    public struct Statistics: Codable, Sendable {
        public var strongEdges = 0
        public var weakEdges = 0
        public var droppedAmbiguous = 0
        public var unresolvedExternal = 0
    }

    public let index: ASTIndex
    public private(set) var outgoing: [SymbolID: [Edge]] = [:]
    public private(set) var incoming: [SymbolID: [Edge]] = [:]
    public private(set) var statistics = Statistics()
    /// More candidates than this for an unqualified name is treated as unresolvable.
    public static let maxWeakCandidates = 4

    private let typesByName: [String: [SymbolID]]
    private let membersByName: [String: [SymbolID]]
    /// Type -> protocol names from its declaration and all its extensions.
    private let conformancesByType: [SymbolID: [String]]

    public init(index: ASTIndex) {
        self.index = index
        var types: [String: [SymbolID]] = [:]
        var members: [String: [SymbolID]] = [:]
        var conformances: [SymbolID: [String]] = [:]
        for d in index.declarations.values {
            if d.kind.isType { types[d.name, default: []].append(d.id) }
            if d.container != nil || d.kind == .function { members[d.name, default: []].append(d.id) }
            if d.kind.isNominalOrExtension {
                let type = d.kind == .extension ? SymbolID(rawValue: "\(d.module).\(d.name)") : d.id
                conformances[type, default: []] += d.inheritance.compactMap(SwiftFileIndexer.baseTypeName)
            }
        }
        typesByName = types.mapValues { $0.sorted() }
        membersByName = members.mapValues { $0.sorted() }
        conformancesByType = conformances.mapValues { Array(Set($0)).sorted() }
        build()
    }

    // MARK: Queries

    public func definition(_ id: SymbolID) -> Declaration? { index[id] }

    /// Declarations that reference `id`, strongest edge per source.
    public func referrers(of id: SymbolID, minimum: Strength = .strong) -> [Edge] {
        Self.strongestPerEndpoint(incoming[id] ?? [], key: \.from).filter { $0.strength >= minimum }
    }

    public func references(from id: SymbolID, minimum: Strength = .strong) -> [Edge] {
        Self.strongestPerEndpoint(outgoing[id] ?? [], key: \.to).filter { $0.strength >= minimum }
    }

    /// Simple type name of a container symbol: `M.Outer.Inner` -> `Inner`.
    static func simpleName(_ id: SymbolID) -> String { String(id.rawValue.split(separator: ".").last ?? "") }

    private static func strongestPerEndpoint(_ edges: [Edge], key: KeyPath<Edge, SymbolID>) -> [Edge] {
        // Strongest edge per endpoint; ties prefer the most specific relation, so the choice is deterministic.
        let rank: [Relation] = [.calls, .constructs, .implements, .references, .conforms, .extends]
        func better(_ a: Edge, than b: Edge) -> Bool {
            a.strength != b.strength ? b.strength < a.strength : rank.firstIndex(of: a.relation)! < rank.firstIndex(of: b.relation)!
        }
        var best: [SymbolID: Edge] = [:]
        for e in edges where best[e[keyPath: key]].map({ better(e, than: $0) }) ?? true { best[e[keyPath: key]] = e }
        return best.values.sorted { $0[keyPath: key] < $1[keyPath: key] }
    }

    // MARK: Build

    private mutating func build() {
        for d in index.declarations.values.sorted(by: { $0.id < $1.id }) {
            if let body = d.body {
                for r in body.references { resolve(r, in: d) }
            }
            // Signature types (parameters, return, property type) are references too: changing `T` affects users of `T`.
            for t in d.parameters.map(\.type) + [d.returnType].compactMap({ $0 }) {
                for name in Self.typeNames(in: t) { linkTypes(name, from: d, line: nil, relation: .references) }
            }
            if d.kind.isNominalOrExtension {
                for p in d.inheritance { for name in Self.typeNames(in: p) { linkTypes(name, from: d, line: nil, relation: .conforms) } }
            }
            if d.kind == .extension { linkTypes(d.name, from: d, line: nil, relation: .extends) }
        }
        linkProtocolImplementations()
    }

    private mutating func resolve(_ r: Reference, in d: Declaration) {
        switch r.kind {
        case .type:
            linkTypes(r.name, from: d, line: r.line, relation: .references)
        case .call where r.name.first?.isUppercase == true && r.qualifier == nil:
            // `T(...)`: the type and its initializers.
            let types = candidatesPreferringModule(typesByName[r.name] ?? [], d.module)
            guard !types.isEmpty else { statistics.unresolvedExternal += 1; return }
            let strength: Strength = types.count == 1 ? .strong : .weak
            for t in types {
                add(Edge(from: d.id, to: t, relation: .constructs, strength: strength, line: r.line))
                for i in index.members(of: t) where i.kind == .initializer {
                    add(Edge(from: d.id, to: i.id, relation: .constructs, strength: strength, line: r.line))
                }
            }
        case .call, .member:
            let all = membersByName[r.name] ?? []
            guard !all.isEmpty else { statistics.unresolvedExternal += 1; return }
            let relation: Relation = r.kind == .call ? .calls : .references
            if let narrowed = narrow(all, r, d), !narrowed.isEmpty {
                for c in narrowed { add(Edge(from: d.id, to: c, relation: relation, strength: .strong, line: r.line)) }
                return
            }
            let pool = candidatesPreferringModule(all, d.module)
            if pool.count == 1 {
                add(Edge(from: d.id, to: pool[0], relation: relation, strength: .strong, line: r.line))
            } else if pool.count <= Self.maxWeakCandidates {
                for c in pool { add(Edge(from: d.id, to: c, relation: relation, strength: .weak, line: r.line)) }
            } else {
                statistics.droppedAmbiguous += 1
            }
        }
    }

    /// Candidates restricted by what the receiver tells us; nil when the receiver gives no information.
    private func narrow(_ candidates: [SymbolID], _ r: Reference, _ d: Declaration) -> [SymbolID]? {
        func members(ofTypeNamed name: String) -> [SymbolID] {
            let simple = name.split(separator: ".").last.map(String.init) ?? name
            return candidates.filter { c in index[c]?.container.map(Self.simpleName) == simple }
        }
        switch r.qualifier {
        case nil, "self":
            if let container = d.container {
                let own = candidates.filter { index[$0]?.container == container }
                if !own.isEmpty { return own }
                // Members inherited from protocols the container (or its extensions) conforms to.
                let inherited = conformedProtocols(of: container).flatMap { members(ofTypeNamed: $0) }
                if !inherited.isEmpty { return inherited }
            }
            if r.qualifier == nil {
                let free = candidates.filter { index[$0]?.kind == .function }
                if !free.isEmpty { return free }
            }
            return nil
        case ".":
            let implicit = candidates.filter { index[$0].map { $0.kind == .enumCase || $0.isStatic } ?? false }
            return implicit.count == 1 ? implicit : nil
        case "super":
            return nil
        case let q?:
            if q.first?.isUppercase == true { return members(ofTypeNamed: q) }
            if let t = r.receiverType ?? propertyType(named: q, in: d) { return members(ofTypeNamed: t) }
            return nil
        }
    }

    private func propertyType(named name: String, in d: Declaration) -> String? {
        guard let container = d.container else { return nil }
        let prop = index.members(of: container).first { $0.kind == .property && $0.name == name }
        return prop?.returnType.flatMap(SwiftFileIndexer.baseTypeName)
    }

    private func conformedProtocols(of type: SymbolID) -> [String] { conformancesByType[type] ?? [] }

    private func candidatesPreferringModule(_ ids: [SymbolID], _ module: String) -> [SymbolID] {
        let same = ids.filter { index[$0]?.module == module }
        return same.isEmpty ? ids : same
    }

    private mutating func linkTypes(_ name: String, from d: Declaration, line: Int?, relation: Relation) {
        guard let simple = name.split(separator: ".").last.map(String.init), let types = typesByName[simple] else {
            statistics.unresolvedExternal += 1
            return
        }
        let pool = candidatesPreferringModule(types, d.module).filter { $0 != d.id }
        let strength: Strength = pool.count == 1 ? .strong : .weak
        guard pool.count <= Self.maxWeakCandidates else { statistics.droppedAmbiguous += 1; return }
        for t in pool { add(Edge(from: d.id, to: t, relation: relation, strength: strength, line: line)) }
    }

    /// `T.m` implements requirement `P.m` when `T` conforms to `P` (in its declaration or any extension) and both share
    /// a selector. Callers through the protocol then reach the implementation.
    private mutating func linkProtocolImplementations() {
        let protocols = index.declarations.values.filter { $0.kind == .protocol }
        for p in protocols.sorted(by: { $0.id < $1.id }) {
            let requirements = index.members(of: p.id)
            guard !requirements.isEmpty else { continue }
            for conformer in index.conformances(to: p.name) {
                let typeID = conformer.kind == .extension ? SymbolID(rawValue: "\(conformer.module).\(conformer.name)") : conformer.id
                let implementations = index.members(of: typeID)
                for req in requirements {
                    for impl in implementations where impl.kind == req.kind && impl.id.leaf == req.id.leaf {
                        add(Edge(from: req.id, to: impl.id, relation: .implements, strength: .strong, line: nil))
                    }
                }
            }
        }
    }

    private mutating func add(_ e: Edge) {
        guard e.from != e.to else { return }
        outgoing[e.from, default: []].append(e)
        incoming[e.to, default: []].append(e)
        if e.strength == .strong { statistics.strongEdges += 1 } else { statistics.weakEdges += 1 }
    }

    /// Identifier-like type names inside a type expression: `[String: Foo<Bar>]?` -> Foo, Bar, String.
    static func typeNames(in type: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in type {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." { current.append(ch) } else {
                if let f = current.first, f.isUppercase { out.append(current) }
                current = ""
            }
        }
        if let f = current.first, f.isUppercase { out.append(current) }
        return out
    }
}
