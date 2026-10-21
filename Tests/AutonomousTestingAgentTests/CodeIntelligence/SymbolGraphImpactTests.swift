import Testing
import Foundation
@testable import CodeIntelligence

@Suite("Code intelligence: symbol graph, impact and test discovery")
struct SymbolGraphImpactTests {
    typealias F = CodeIntelligenceFixtures

    static let chain = """
    struct B { func b() {} }
    struct A { let dep: B; func a() { dep.b() } }
    struct C { let a: A; func c() { a.a() } }
    struct D { let c: C; func d() { c.c() } }
    """

    func change(_ id: SymbolID, file: String = "Sources/Core/Chain.swift") -> ChangeSet {
        ChangeSet(base: "t", files: [], symbols: [SymbolChange(symbol: id, kind: .modified, aspects: [.body], declarationKind: .method, file: file,
                                                               role: .production, isInterface: true, isPublicAPI: false)], apiChanges: [], diagnostics: [])
    }

    @Test func testCallsThroughTypedPropertiesAreStrongEdges() {
        let g = SymbolGraph(index: F.index(["Sources/Core/Chain.swift": Self.chain]))
        let callers = g.referrers(of: "Core.B.b()").map(\.from)
        #expect(callers == ["Core.A.a()"])
        #expect(g.referrers(of: "Core.B.b()").first?.relation == .calls)
    }

    @Test func testImpactClassifiesDirectAndIndirectAndStopsAtTheConfiguredDepth() throws {
        let g = SymbolGraph(index: F.index(["Sources/Core/Chain.swift": Self.chain]))
        let slice = try #require(ImpactAnalyzer.analyze(change("Core.B.b()"), graph: g).slices.first)
        #expect(slice.nodes.map(\.symbol) == ["Core.A.a()", "Core.C.c()"])
        #expect(slice.nodes.map(\.impact) == [.direct, .indirect])
        #expect(slice.path(to: "Core.C.c()") == ["Core.B.b()", "Core.A.a()", "Core.C.c()"])

        let deeper = try #require(ImpactAnalyzer.analyze(change("Core.B.b()"), graph: g, configuration: ImpactConfiguration().expanded()).slices.first)
        #expect(deeper.nodes.last?.symbol == "Core.D.d()")
        #expect(deeper.nodes.last?.impact == .transitive)
    }

    @Test func testCallersThroughAProtocolReachTheImplementation() throws {
        let src = """
        protocol Runner { func run() }
        struct Fast: Runner { func run() {} }
        struct Client { let r: any Runner; func go() { r.run() } }
        """
        let g = SymbolGraph(index: F.index(["Sources/Core/P.swift": src]))
        #expect(g.references(from: "Core.Runner.run()").contains { $0.to == "Core.Fast.run()" && $0.relation == .implements })
        let slice = try #require(ImpactAnalyzer.analyze(change("Core.Fast.run()", file: "Sources/Core/P.swift"), graph: g).slices.first)
        #expect(slice.nodes.map(\.symbol) == ["Core.Client.go()"])
        #expect(slice.nodes.first?.impact == .direct)
    }

    @Test func testAmbiguousNamesBecomeWeakEdgesThatDefaultImpactIgnores() throws {
        let src = """
        struct X { func start() {} }
        struct Y { func start() {} }
        struct Z { func go(_ o: AnyObject) { unknown.start() } }
        """
        let g = SymbolGraph(index: F.index(["Sources/Core/Amb.swift": src]))
        #expect(g.referrers(of: "Core.X.start()").isEmpty)
        #expect(g.referrers(of: "Core.X.start()", minimum: .weak).map(\.from) == ["Core.Z.go(_:)"])
        let c = change("Core.X.start()", file: "Sources/Core/Amb.swift")
        #expect(try #require(ImpactAnalyzer.analyze(c, graph: g).slices.first).nodes.isEmpty)
        #expect(try #require(ImpactAnalyzer.analyze(c, graph: g, configuration: ImpactConfiguration().expanded()).slices.first).nodes.count == 1)
    }

    @Test func testTestsAreDiscoveredWithFrameworkAssertionsAndTheSymbolsTheyExercise() throws {
        let index = F.index(F.package.merging(["Tests/CoreTests/LegacyTests.swift": """
            import XCTest
            final class LegacyTests: XCTestCase { func testImportsNothing() { XCTAssertEqual(1, 1) } }
            """]) { a, _ in a })
        let tests = TestIndexer.build(graph: SymbolGraph(index: index))
        let roundTrip = try #require(tests.tests["CoreTests.RecordStoreTests.testSaveThenLoadRoundTrip()"])
        #expect(roundTrip.framework == .swiftTesting)
        #expect(roundTrip.displayName == "Saved data loads back")
        #expect(roundTrip.suiteDisplayName == "Record store")
        #expect(roundTrip.isAsync && roundTrip.isThrows)
        #expect(roundTrip.assertionCount == 1)
        #expect(Set(roundTrip.referencedSymbols).isSuperset(of: ["Core.RecordStore.save(_:forKey:)", "Core.RecordStore.load(_:)", "Core.RecordStore.init()"]))

        let missing = try #require(tests.tests["CoreTests.RecordStoreTests.testLoadOfMissingKeyThrows()"])
        #expect(missing.expectsThrow)
        #expect(tests.tests(covering: "Core.RecordStore.load(_:)").map(\.name).sorted() == ["testLoadOfMissingKeyThrows", "testSaveThenLoadRoundTrip"])

        let legacy = try #require(tests.tests["CoreTests.LegacyTests.testImportsNothing()"])
        #expect(legacy.framework == .xctest)
        #expect(legacy.assertionCount == 1)
        #expect(tests.conventions.dominantFramework == .swiftTesting)
    }

    @Test func testImpactFindsTestsThroughTestHelpers() throws {
        let files = [
            "Sources/Core/Chain.swift": Self.chain,
            "Tests/CoreTests/Support/Harness.swift": "struct Harness { func drive(_ a: A) { a.a() } }",
            "Tests/CoreTests/ChainTests.swift": "import Testing\n@Suite struct ChainTests { let h = Harness(); @Test func testDrive() { h.drive(A(dep: B())) } }",
        ]
        let g = SymbolGraph(index: F.index(files))
        let slice = try #require(ImpactAnalyzer.analyze(change("Core.B.b()"), graph: g).slices.first)
        #expect(slice.tests == ["CoreTests.ChainTests.testDrive()"])
        #expect(!slice.nodes.contains { $0.file.hasPrefix("Tests/") }, "test code is reported as tests, not as production impact")
    }
}
