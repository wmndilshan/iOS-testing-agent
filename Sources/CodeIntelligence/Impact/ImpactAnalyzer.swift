import Foundation

/// How a symbol is affected by a change.
/// `direct` = references a changed symbol; `indirect` = one layer further; `transitive` = beyond that.
public enum ImpactClass: String, Codable, Sendable, Comparable {
    case direct, indirect, transitive, testOnly, documentationOnly
    private var rank: Int { [.direct, .indirect, .transitive, .testOnly, .documentationOnly].firstIndex(of: self)! }
    public static func < (a: ImpactClass, b: ImpactClass) -> Bool { a.rank < b.rank }
}

public struct ImpactConfiguration: Codable, Sendable {
    /// 1 = direct referrers only; 2 = plus one transitive layer (default).
    public var maxDepth = 2
    public var maxNodesPerSymbol = 30
    /// Referrers fanned out per node beyond depth 1; keeps hub symbols from exploding the slice.
    public var maxFanOutBeyondDirect = 8
    public var minimumStrength: SymbolGraph.Strength = .strong
    public init() {}

    /// The next escalation: one layer deeper and weak (ambiguous) edges included.
    public func expanded() -> ImpactConfiguration {
        var c = self
        c.maxDepth += 1
        c.maxNodesPerSymbol *= 2
        c.minimumStrength = .weak
        return c
    }
}

public struct ImpactNode: Codable, Hashable, Sendable {
    public var symbol: SymbolID
    public var impact: ImpactClass
    public var depth: Int
    /// The symbol this one reaches the change through (its callee on the path).
    public var via: SymbolID
    public var relation: SymbolGraph.Relation
    public var strength: SymbolGraph.Strength
    public var file: String
}

public struct ImpactSlice: Codable, Sendable {
    public var changed: SymbolID
    public var nodes: [ImpactNode]
    /// Test functions (in test targets) that reach the changed symbol, directly or through test helpers.
    public var tests: [SymbolID]
    /// For protocol requirements: implementations in conforming types.
    public var implementations: [SymbolID]
    public var truncated: Bool

    /// `changed <- a <- b` for a node, following `via` links.
    public func path(to symbol: SymbolID) -> [SymbolID] {
        var out = [symbol]
        var current = symbol
        while let n = nodes.first(where: { $0.symbol == current }), n.via != changed, out.count < 10 {
            out.append(n.via)
            current = n.via
        }
        return [changed] + out.reversed()
    }
}

public struct ImpactReport: Codable, Sendable {
    public var slices: [ImpactSlice]
    public var configuration: ImpactConfiguration
    /// Change-level classification when no production code changed.
    public var scope: ImpactClass?
    public var affectedFiles: [String] {
        Array(Set(slices.flatMap { $0.nodes.map(\.file) })).sorted()
    }
    public var allTests: [SymbolID] { Array(Set(slices.flatMap(\.tests))).sorted() }
}

public enum ImpactAnalyzer {

    public static func analyze(_ changes: ChangeSet, graph: SymbolGraph, configuration: ImpactConfiguration = .init()) -> ImpactReport {
        let scope: ImpactClass? = changes.isDocumentationOnly ? .documentationOnly : (changes.isTestOnly ? .testOnly : nil)
        let roots = changes.productionSymbols.filter { $0.kind != .added || $0.isInterface }.map(\.symbol)
        let slices = roots.compactMap { root -> ImpactSlice? in
            // A removed symbol has no definition in the new index; its referrers (if any remain) are compile errors.
            guard graph.index[root] != nil else { return nil }
            return slice(for: root, graph: graph, configuration: configuration)
        }
        return ImpactReport(slices: slices, configuration: configuration, scope: scope)
    }

    static func slice(for root: SymbolID, graph: SymbolGraph, configuration c: ImpactConfiguration) -> ImpactSlice {
        var nodes: [SymbolID: ImpactNode] = [:]
        var tests = Set<SymbolID>()
        var truncated = false
        let implementations = graph.references(from: root).filter { $0.relation == .implements }.map(\.to)

        // Breadth-first over referrers. A protocol requirement's callers reach its implementations, so for an
        // implementation we also walk the requirement's referrers at the same depth (the `implements` hop is free).
        var frontier: [(SymbolID, Int)] = [(root, 0)]
        var seen: Set<SymbolID> = [root]
        while !frontier.isEmpty {
            var next: [(SymbolID, Int)] = []
            for (symbol, depth) in frontier {
                var edges = graph.referrers(of: symbol, minimum: c.minimumStrength)
                for req in edges.filter({ $0.relation == .implements }).map(\.from) {
                    edges += graph.referrers(of: req, minimum: c.minimumStrength).map { e in var e = e; e.to = symbol; return e }
                }
                edges = edges.filter { $0.relation != .implements }
                if depth >= 1, edges.count > c.maxFanOutBeyondDirect { truncated = true; edges = Array(prioritized(edges, graph).prefix(c.maxFanOutBeyondDirect)) }
                for e in edges where !seen.contains(e.from) {
                    guard let d = graph.index[e.from], let role = graph.index.files[d.span.file]?.role else { continue }
                    seen.insert(e.from)
                    if role == .test || role == .testSupport {
                        if isTestFunction(d) { tests.insert(d.id) } else if depth + 1 <= c.maxDepth + 1 {
                            // Test helpers (fixtures, harnesses, suite helpers) are walked to find the tests using them.
                            next.append((d.id, depth + 1))
                        }
                        continue
                    }
                    guard depth + 1 <= c.maxDepth else { continue }
                    guard nodes.count < c.maxNodesPerSymbol else { truncated = true; continue }
                    nodes[d.id] = ImpactNode(symbol: d.id, impact: depth == 0 ? .direct : (depth == 1 ? .indirect : .transitive), depth: depth + 1,
                                             via: symbol, relation: e.relation, strength: e.strength, file: d.span.file)
                    next.append((d.id, depth + 1))
                }
            }
            frontier = next
        }
        return ImpactSlice(changed: root, nodes: nodes.values.sorted { ($0.depth, $0.symbol) < ($1.depth, $1.symbol) },
                           tests: tests.sorted(), implementations: implementations.sorted(), truncated: truncated)
    }

    /// Production before tests, cross-module before same-module, then by ID: stable and favours interface boundaries.
    private static func prioritized(_ edges: [SymbolGraph.Edge], _ graph: SymbolGraph) -> [SymbolGraph.Edge] {
        edges.sorted { a, b in
            let ra = graph.index.role(of: a.from) == .production ? 0 : 1
            let rb = graph.index.role(of: b.from) == .production ? 0 : 1
            if ra != rb { return ra < rb }
            if a.strength != b.strength { return b.strength < a.strength }
            return a.from < b.from
        }
    }

    static func isTestFunction(_ d: Declaration) -> Bool {
        guard d.kind == .method || d.kind == .function else { return false }
        return d.attributes.contains("Test") || (d.name.hasPrefix("test") && d.parameters.isEmpty)
    }
}
