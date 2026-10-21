import Testing
import Foundation
@testable import CodeIntelligence

@Suite("Code intelligence: change analysis")
struct ChangeAnalyzerTests {
    typealias F = CodeIntelligenceFixtures
    static let path = "Sources/Core/Gate.swift"

    static let before = """
    public struct Gate {
        public func admit(_ n: Int) throws -> Bool {
            guard n > 0 else { throw GateError.negative }
            return n < 10
        }
        func helper() {}
    }
    public enum GateError: Error { case negative, tooLarge }
    """

    func analyze(_ old: String?, _ new: String?, status: FileChangeStatus = .modified) -> ChangeSet {
        ChangeAnalyzer.analyze([RawFileChange(path: Self.path, status: status, oldText: old, newText: new)], base: "test")
    }

    @Test func testCommentOnlyEditsProduceNoSymbolChange() {
        let edited = Self.before.replacingOccurrences(of: "    func helper() {}", with: "    /// Explains helper.\n    func helper() { /* nothing */ }")
        let c = analyze(Self.before, edited)
        #expect(c.files.count == 1)
        #expect(c.symbols.isEmpty)
    }

    @Test func testAnAddedGuardIsAControlFlowAndErrorHandlingChangeWithTheNewBranchRecorded() throws {
        let after = Self.before.replacingOccurrences(of: "        return n < 10", with: "        guard n < 100 else { throw GateError.tooLarge }\n        return n < 10")
        let s = try #require(analyze(Self.before, after).symbols.first)
        #expect(s.symbol == "Core.Gate.admit(_:)")
        #expect(s.kind == .modified)
        #expect(s.aspects == [.errorHandling, .controlFlow, .body])
        #expect(s.addedBranches == ["guard n < 100"])
        #expect(s.removedBranches.isEmpty)
        #expect(!s.isSignatureChange)
    }

    @Test func testALabelRenameKeepsTheSymbolAsAModifiedSignatureWithItsPreviousID() throws {
        let after = Self.before.replacingOccurrences(of: "admit(_ n: Int)", with: "admit(count n: Int)")
        let c = analyze(Self.before, after)
        let s = try #require(c.symbols.first { $0.symbol == "Core.Gate.admit(count:)" })
        #expect(s.kind == .modified)
        #expect(s.previousSymbol == "Core.Gate.admit(_:)")
        #expect(s.aspects.contains(.signature) && s.aspects.contains(.parameters))
        #expect(s.isPublicAPI)
        #expect(c.apiChanges == ["Core.Gate.admit(count:)"])
    }

    @Test func testEffectAccessAndIsolationChangesAreSeparateAspects() throws {
        let after = Self.before.replacingOccurrences(of: "public func admit(_ n: Int) throws -> Bool", with: "@MainActor func admit(_ n: Int) async throws -> Bool")
        let s = try #require(analyze(Self.before, after).symbols.first)
        #expect(Set(s.aspects).isSuperset(of: [.access, .async, .isolation, .attributes, .signature]))
    }

    @Test func testAddedAndDeletedFilesAddAndRemoveEverySymbol() {
        let added = analyze(nil, Self.before, status: .added)
        #expect(added.symbols.allSatisfy { $0.kind == .added })
        let removed = analyze(Self.before, nil, status: .deleted)
        #expect(removed.symbols.allSatisfy { $0.kind == .removed })
        #expect(removed.apiChanges.contains("Core.Gate.admit(_:)"))
    }

    @Test func testWithoutABaselineEveryDeclarationIsConservativelyModified() {
        let c = analyze(nil, Self.before, status: .modified)
        #expect(!c.symbols.isEmpty && c.symbols.allSatisfy { $0.kind == .modified })
        #expect(c.diagnostics.contains { $0.contains("no baseline") })
    }

    @Test func testDocumentationAndTestOnlyChangesAreClassified() {
        let docs = ChangeAnalyzer.analyze([RawFileChange(path: "docs/A.md", status: .modified, oldText: "a", newText: "b")], base: "t")
        #expect(docs.isDocumentationOnly && docs.symbols.isEmpty)
        let tests = ChangeAnalyzer.analyze([RawFileChange(path: "Tests/CoreTests/ATests.swift", status: .added, oldText: nil, newText: "struct ATests {}")], base: "t")
        #expect(tests.isTestOnly && !tests.isDocumentationOnly)
    }

    @Test func testUnifiedDiffHunkHeadersBecomeLineRanges() {
        let diff = """
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -3,2 +3,4 @@ struct A {
        +x
        @@ -10 +12,0 @@
        diff --git a/B.swift b/B.swift
        --- a/B.swift
        +++ /dev/null
        @@ -1,5 +0,0 @@
        """
        let h = UnifiedDiffParser.parse(diff)
        #expect(h["A.swift"] == .init(added: [3...6], removed: [3...4, 10...10]))
        #expect(h["B.swift"] == .init(added: [], removed: [1...5]))
    }

    @Test func testLineDiffFindsInsertedLines() {
        #expect(LineDiff.changedLines(old: "a\nb\nc", new: "a\nx\nb\nc") == [2...2])
        #expect(LineDiff.changedLines(old: "a\nb", new: "a\nb").isEmpty)
    }

    @Test func testSnapshotSourceComparesTwoTrees() throws {
        let base = try F.tree(["Sources/Core/Gate.swift": Self.before, "docs/Notes.md": "x"])
        let now = try F.tree(["Sources/Core/Gate.swift": Self.before + "\nstruct Extra {}", "Sources/Core/New.swift": "struct New {}"])
        defer { F.remove(base); F.remove(now) }
        let changes = try SnapshotChangeSource(root: now, baseline: base).changes()
        #expect(changes.map(\.path) == ["Sources/Core/Gate.swift", "Sources/Core/New.swift", "docs/Notes.md"])
        #expect(changes.map(\.status) == [.modified, .added, .deleted])
        #expect(changes[0].changedLines == [9...9])
    }

    @Test func testRevisionsAreValidatedBeforeAnyGitCall() throws {
        #expect(GitChangeSource.isValidRevision("HEAD~2"))
        #expect(GitChangeSource.isValidRevision("origin/main"))
        #expect(!GitChangeSource.isValidRevision("--output=/tmp/x"))
        #expect(!GitChangeSource.isValidRevision("a..b"))
        #expect(!GitChangeSource.isValidRevision("HEAD; rm -rf /"))
        #expect(throws: ChangeSourceError.invalidRevision("-p")) { try GitChangeSource(root: URL(fileURLWithPath: "/tmp"), base: "-p").changes() }
    }

    @Test func testTheGitRunnerRefusesMutatingSubcommands() {
        let runner = GitCommandRunner(workingDirectory: URL(fileURLWithPath: "/tmp"))
        for sub in ["commit", "checkout", "reset", "push", "config", "clean", "stash"] {
            #expect(throws: ChangeSourceError.disallowedGitCommand(sub)) { try runner.run(sub, []) }
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git")))
    func testGitSourceReportsWorkingTreeChangesAgainstHEAD() throws {
        let root = try F.tree(["Sources/Core/Gate.swift": Self.before, "Sources/Core/Old.swift": "struct Old {}"])
        defer { F.remove(root) }
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + args
            p.currentDirectoryURL = root
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "git \(args)")
        }
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-q", "-m", "base")
        let after = Self.before.replacingOccurrences(of: "        return n < 10", with: "        guard n < 100 else { throw GateError.tooLarge }\n        return n < 10")
        try after.write(to: root.appendingPathComponent("Sources/Core/Gate.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Core/Old.swift"))
        try "struct Fresh {}".write(to: root.appendingPathComponent("Sources/Core/Fresh.swift"), atomically: true, encoding: .utf8)

        let raw = try GitChangeSource(root: root).changes()
        #expect(raw.map(\.path) == ["Sources/Core/Fresh.swift", "Sources/Core/Gate.swift", "Sources/Core/Old.swift"])
        #expect(raw.map(\.status) == [.added, .modified, .deleted])
        let gate = try #require(raw.first { $0.path.hasSuffix("Gate.swift") })
        #expect(gate.oldText == Self.before)
        #expect(gate.changedLines == [4...4])
        let set = ChangeAnalyzer.analyze(raw, base: "git:HEAD")
        #expect(set.symbols.first { $0.symbol == "Core.Gate.admit(_:)" }?.addedBranches == ["guard n < 100"])
    }
}
