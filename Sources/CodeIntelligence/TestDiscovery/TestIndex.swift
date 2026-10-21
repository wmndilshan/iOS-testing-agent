import Foundation

public enum TestFramework: String, Codable, Sendable { case swiftTesting, xctest, xcuitest }

public struct TestCaseFacts: Codable, Hashable, Sendable {
    public var id: SymbolID
    public var suite: SymbolID?
    public var suiteDisplayName: String?
    public var name: String
    public var displayName: String?
    public var framework: TestFramework
    public var target: String
    public var span: SourceSpan
    /// Production symbols the test exercises: its own strong references plus those of the suite helpers, suite
    /// initializer/properties and test-support helpers it calls (one level).
    public var referencedSymbols: [SymbolID]
    /// Types owning the referenced members (type-level coverage).
    public var referencedTypes: [SymbolID]
    public var mocks: [String]
    public var fixtures: [String]
    public var assertionCount: Int
    public var expectsThrow: Bool
    public var isAsync: Bool
    public var isThrows: Bool
    public var tags: [String]
    public var isParameterized: Bool
}

/// Project test conventions, inferred (not configured) from the existing tests.
public struct TestConventions: Codable, Sendable {
    public var frameworkCounts: [String: Int]
    public var dominantFramework: TestFramework
    /// Test targets (SwiftPM) and the modules their tests reference most.
    public var targets: [String]
    /// Shared fakes and fixtures (types declared in test-support files).
    public var supportTypes: [String]
    public var suiteDeclarationStyle: String
}

public struct TestIndex: Codable, Sendable {
    public var tests: [SymbolID: TestCaseFacts]
    /// Production symbol -> tests referencing it.
    public var bySymbol: [SymbolID: [SymbolID]]
    /// Production type -> tests referencing any of its members.
    public var byType: [SymbolID: [SymbolID]]
    public var conventions: TestConventions

    public func tests(covering symbol: SymbolID) -> [TestCaseFacts] { (bySymbol[symbol] ?? []).compactMap { tests[$0] } }
    public func tests(exercisingType type: SymbolID) -> [TestCaseFacts] { (byType[type] ?? []).compactMap { tests[$0] } }
}

public enum TestIndexer {
    static let mockMarkers = ["Mock", "Fake", "Stub", "Spy", "InMemory", "Recording", "Scripted", "Sequential", "Tick", "TestClock"]

    public static func build(graph: SymbolGraph) -> TestIndex {
        let index = graph.index
        let testDecls = index.declarations.values.filter { d in
            guard let role = index.files[d.span.file]?.role, role == .test || role == .testSupport else { return false }
            return ImpactAnalyzer.isTestFunction(d)
        }
        let supportTypes = index.declarations.values.filter { d in d.kind.isType && index.files[d.span.file]?.role == .testSupport }.map(\.name)
        let supportTypeSet = Set(supportTypes)

        var tests: [SymbolID: TestCaseFacts] = [:]
        var bySymbol: [SymbolID: Set<SymbolID>] = [:]
        var byType: [SymbolID: Set<SymbolID>] = [:]
        var frameworkCounts: [String: Int] = [:]
        for d in testDecls.sorted(by: { $0.id < $1.id }) {
            let suite = d.container.flatMap { index[$0] }
            let file = index.files[d.span.file]
            let framework: TestFramework = d.attributes.contains("Test") ? .swiftTesting
                : ((file?.module.contains("UITest") ?? false) || (d.body?.referencedNames.contains("XCUIApplication") ?? false) ? .xcuitest : .xctest)
            frameworkCounts[framework.rawValue, default: 0] += 1

            // The test body, plus one level of helpers declared in test code (suite helpers, support fixtures).
            var reached = Set<SymbolID>()
            var helperSources: [SymbolID] = [d.id]
            if let suite {
                helperSources += index.members(of: suite.id).filter { $0.kind == .initializer || ($0.kind == .property && !$0.isStatic) }.map(\.id)
            }
            for source in helperSources {
                for e in graph.references(from: source) {
                    guard let target = index[e.to], let role = index.files[target.span.file]?.role else { continue }
                    if role == .production { reached.insert(e.to) } else if !ImpactAnalyzer.isTestFunction(target) {
                        for inner in graph.references(from: e.to) where index.role(of: inner.to) == .production { reached.insert(inner.to) }
                    }
                }
            }
            let referencedNames = d.body?.referencedNames ?? []
            let referencedTypes = Set(reached.compactMap { index[$0]?.container } + reached.filter { index[$0]?.kind.isType ?? false })
            let mocks = referencedNames.filter { n in n.first?.isUppercase == true && mockMarkers.contains { n.contains($0) } }
            let args = d.attributeArguments["Test"] ?? ""
            let facts = TestCaseFacts(
                id: d.id, suite: suite?.id, suiteDisplayName: suite.flatMap { firstStringLiteral($0.attributeArguments["Suite"] ?? "") },
                name: d.name, displayName: firstStringLiteral(args), framework: framework, target: d.module, span: d.span,
                referencedSymbols: reached.sorted(), referencedTypes: referencedTypes.sorted(),
                mocks: mocks.sorted(), fixtures: referencedNames.filter { supportTypeSet.contains($0) }.sorted(),
                assertionCount: (d.body?.macroUses ?? [:]).filter { ["expect", "require"].contains($0.key) || $0.key.hasPrefix("XCTAssert") || $0.key == "XCTFail" }.values.reduce(0, +),
                expectsThrow: (d.body?.throwExpectations ?? 0) > 0, isAsync: d.isAsync, isThrows: d.isThrows,
                tags: tags(args + " " + (suite?.attributeArguments["Suite"] ?? "")), isParameterized: args.contains("arguments:"))
            tests[d.id] = facts
            for s in facts.referencedSymbols { bySymbol[s, default: []].insert(d.id) }
            for t in facts.referencedTypes { byType[t, default: []].insert(d.id) }
        }
        let dominant = frameworkCounts.max { ($0.value, $0.key) < ($1.value, $1.key) }.flatMap { TestFramework(rawValue: $0.key) } ?? .swiftTesting
        let suitesWithAttribute = index.declarations.values.filter { $0.attributes.contains("Suite") }.count
        let conventions = TestConventions(
            frameworkCounts: frameworkCounts, dominantFramework: dominant,
            targets: Array(Set(tests.values.map(\.target))).sorted(), supportTypes: supportTypes.sorted(),
            suiteDeclarationStyle: suitesWithAttribute > 0 ? "@Suite(\"<name>\") struct <Area>Tests with @Test func test<Behavior>()" : "final class <Area>Tests: XCTestCase")
        return TestIndex(tests: tests, bySymbol: bySymbol.mapValues { $0.sorted() }, byType: byType.mapValues { $0.sorted() }, conventions: conventions)
    }

    static func firstStringLiteral(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "\"") else { return nil }
        let rest = s[s.index(after: start)...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// `.tags(.critical, .persistence)` -> ["critical", "persistence"].
    static func tags(_ s: String) -> [String] {
        guard let r = s.range(of: ".tags(") else { return [] }
        let inner = s[r.upperBound...].prefix { $0 != ")" }
        return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }.sorted()
    }
}
