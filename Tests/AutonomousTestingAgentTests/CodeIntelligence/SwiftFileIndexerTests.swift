import Testing
import Foundation
@testable import CodeIntelligence

@Suite("Code intelligence: AST index")
struct SwiftFileIndexerTests {
    typealias F = CodeIntelligenceFixtures

    @Test func testSymbolIDsUseModuleContainerAndSelector() {
        let ids = Set(F.declarations(F.store, path: "Sources/Core/RecordStore.swift").map(\.id.rawValue))
        #expect(ids.isSuperset(of: [
            "Core.StoreError", "Core.StoreError.missing", "Core.RecordStore", "Core.RecordStore.records", "Core.RecordStore.state",
            "Core.RecordStore.init()", "Core.RecordStore.save(_:forKey:)", "Core.RecordStore.load(_:)", "Core.StoreState.open",
        ]))
    }

    @Test func testOverloadsWithTheSameLabelsAreDisambiguatedByTypes() {
        let src = "struct P { func f(_ a: Int) {}\n func f(_ a: String) {}\n func f(x: Int) {} }"
        let ids = Set(F.declarations(src).map(\.id.rawValue))
        #expect(ids.contains("Core.P.f(_:)[Int]"))
        #expect(ids.contains("Core.P.f(_:)[String]"))
        #expect(ids.contains("Core.P.f(x:)"))
    }

    @Test func testExtensionMembersBelongToTheExtendedTypeAndConformancesAreRecorded() throws {
        let src = "struct A {}\nextension A: Equatable, Sendable { func g() {} }"
        let decls = F.declarations(src, path: "Sources/Core/A.swift")
        let g = try #require(decls.first { $0.name == "g" })
        #expect(g.id == "Core.A.g()")
        #expect(g.container == "Core.A")
        #expect(g.extensionContext == "Equatable, Sendable")
        let ext = try #require(decls.first { $0.kind == .extension })
        #expect(ext.id.rawValue == "Core.A{extension:Equatable,Sendable@A.swift}")
        #expect(ext.inheritance == ["Equatable", "Sendable"])
    }

    @Test func testAccessLevelsIgnoreSetterOnlyModifiersAndInheritFromPublicExtensions() throws {
        let src = """
        public struct S { public private(set) var a = 0\n var b = 0\n private func c() {} }
        public extension S { func d() {} }
        """
        let decls = F.declarations(src)
        func access(_ n: String) -> AccessLevel? { decls.first { $0.name == n }?.access }
        #expect(access("a") == .public)
        #expect(access("b") == .internal)
        #expect(access("c") == .private)
        #expect(access("d") == .public)
    }

    @Test func testEffectsGenericsAndAttributesAreCaptured() throws {
        let src = """
        enum E: Error { case x }
        struct K {
            @MainActor @discardableResult
            func run<T: Codable>(_ v: T) async throws(E) -> Int where T: Sendable { 0 }
        }
        """
        let d = try #require(F.declaration("Core.K.run(_:)", in: src))
        #expect(d.isAsync && d.isThrows)
        #expect(d.typedThrows == "E")
        #expect(d.attributes == ["MainActor", "discardableResult"])
        #expect(d.genericParameters == ["T"])
        #expect(d.genericConstraints == ["T: Codable", "T: Sendable"])
        #expect(d.returnType == "Int")
        #expect(d.signature == "@MainActor @discardableResult func run<T: Codable>(_ v: T) async throws(E) -> Int where T: Sendable")
        #expect(d.isolationMarkers == ["MainActor"])
    }

    @Test func testBodyFactsCountBranchesEffectsAndStateWithoutKeepingSource() throws {
        let src = """
        enum Phase { case idle, running, done }
        enum Failure: Error { case bad }
        final class M {
            var phase = Phase.idle
            func step(_ input: Int) async throws {
                guard input > 0 else { throw Failure.bad }
                switch phase {
                case .idle: phase = .running
                case .running, .done: break
                }
                Task { await work() }
                if input > 10 { try await Task.sleep(nanoseconds: 1) }
            }
            func work() async {}
        }
        """
        let b = try #require(F.declaration("Core.M.step(_:)", in: src)?.body)
        #expect(b.guardCount == 1 && b.ifCount == 1 && b.switchCount == 1 && b.caseCount == 2)
        #expect(b.throwCount == 1 && b.tryCount == 1 && b.awaitCount == 2)
        #expect(b.thrownTypes == ["Failure"])
        #expect(b.assignedMembers == ["phase"])
        #expect(b.matchedCases == ["done", "idle", "running"])
        #expect(b.concurrencyConstructs.contains("Task") && b.concurrencyConstructs.contains("Task.sleep"))
        #expect(b.branchConditions.contains("guard input > 0"))
        #expect(b.references.contains { $0.name == "work" && $0.kind == .call })
    }

    @Test func testReceiverTypesAreTakenFromParametersAndLocals() throws {
        let src = """
        struct Box { func open() {} }
        struct U { func use(_ b: Box) { b.open(); let c = Box(); c.open(); let d: Box = b; d.open() } }
        """
        let refs = try #require(F.declaration("Core.U.use(_:)", in: src)?.body?.references)
        let opens = refs.filter { $0.name == "open" }
        #expect(opens.count == 3)
        #expect(opens.allSatisfy { $0.receiverType == "Box" })
    }

    @Test func testCommentsAndWhitespaceDoNotChangeSignaturesOrFingerprints() throws {
        let a = "struct T { func f(_ x: Int) -> Int { if x > 0 { return x }; return 0 } }"
        let b = "struct T {\n  /// Doc.\n  func f( _ x : Int ) -> Int {\n    // why\n    if x > 0 { return x }\n    return 0\n  }\n}"
        let da = try #require(F.declaration("Core.T.f(_:)", in: a))
        let db = try #require(F.declaration("Core.T.f(_:)", in: b))
        #expect(da.signature == db.signature)
        #expect(da.body?.controlFlowFingerprint == db.body?.controlFlowFingerprint)
        #expect(da.body?.bodyFingerprint != nil)
        #expect(db.span.line == 3)
    }

    @Test func testIndexingIsDeterministic() {
        let one = F.declarations(F.store)
        let two = F.declarations(F.store)
        #expect(one == two)
    }

    @Test func testTestFilesAndRolesAreClassifiedFromThePath() {
        #expect(RepositoryScanner.classify("Sources/AgentCore/X.swift") == ("AgentCore", .production))
        #expect(RepositoryScanner.classify("Tests/AppTests/Support/F.swift") == ("AppTests", .testSupport))
        #expect(RepositoryScanner.classify("Tests/AppTests/FooTests.swift") == ("AppTests", .test))
        #expect(RepositoryScanner.classify("docs/A.md").role == .documentation)
    }

    @Test func testScannerSkipsBuildOutputAndGeneratedSourcesAndReusesTheCache() throws {
        let root = try F.tree(["Sources/Core/A.swift": "struct A {}", ".build/x/B.swift": "struct B {}",
                               "Sources/Core/C.generated.swift": "struct C {}", "Sources/Core/D.swift": "// Generated by tool. DO NOT EDIT.\nstruct D {}"])
        defer { F.remove(root) }
        let cache = root.appendingPathComponent("cache.json")
        let first = RepositoryScanner(root: root).buildIndex(cacheURL: cache)
        #expect(first.index.files.keys.sorted() == ["Sources/Core/A.swift"])
        #expect(first.statistics.skippedGenerated == 1)
        let second = RepositoryScanner(root: root).buildIndex(cacheURL: cache)
        #expect(second.statistics.reusedFromCache == 1 && second.statistics.parsed == 0)
    }
}
