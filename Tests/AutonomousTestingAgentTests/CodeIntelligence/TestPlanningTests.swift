import Testing
import Foundation
@testable import CodeIntelligence

@Suite("Code intelligence: traits, gaps, risk and specifications")
struct TestPlanningTests {
    typealias F = CodeIntelligenceFixtures

    static let savePath = "Sources/Core/RecordStore.swift"
    static let changedStore = F.store.replacingOccurrences(
        of: "guard state == .open else { throw StoreError.missing }",
        with: "guard state == .open else { throw StoreError.missing }\n        guard !key.isEmpty else { throw StoreError.corrupt }")

    /// The fixture package after adding a guard to `RecordStore.save`, and the change set for it.
    static func scenario() -> (index: ASTIndex, changes: ChangeSet) {
        precondition(changedStore != F.store, "the fixture edit must apply")
        var files = F.package
        files[savePath] = changedStore
        let changes = ChangeAnalyzer.analyze([RawFileChange(path: savePath, status: .modified, oldText: F.store, newText: changedStore)], base: "test")
        return (F.index(files), changes)
    }

    static func plan(skills: [TestingSkill] = []) -> TestPlan {
        let (index, changes) = scenario()
        var timings: [String: Int] = [:]
        return TestPlanningPipeline(root: URL(fileURLWithPath: "/nonexistent")).plan(changes: changes, index: index, skills: skills, timings: &timings)
    }

    @Test func testTraitsAreDetectedWithEvidence() throws {
        let (index, changes) = Self.scenario()
        let save = try #require(index["Core.RecordStore.save(_:forKey:)"])
        let traits = Dictionary(uniqueKeysWithValues: TraitDetector.detect(save, change: changes.symbols.first, index: index).map { ($0.trait, $0.reason) })
        #expect(traits[.throwing] == "declared `throws`")
        #expect(traits[.concurrency] == "actor isolation")
        #expect(traits[.persistence] == "`store`")
        #expect(traits[.pureLogic] == nil, "an actor store is not pure")
    }

    @Test func testCoverageSeparatesCoveredUnverifiedAndMissing() throws {
        let plan = Self.plan()
        let gap = try #require(plan.gaps.first { $0.symbol == "Core.RecordStore.save(_:forKey:)" })
        let status = Dictionary(uniqueKeysWithValues: gap.behaviors.map { ($0.behavior.id, $0.status) })
        #expect(status["round-trip"] == .covered, "testSaveThenLoadRoundTrip names the round trip")
        #expect(status["expected-failure"] == .unverified, "a test exercises save, none shows the failure path")
        #expect(status["branch-1"] == .missing, "the new guard cannot have a test yet")
        #expect(gap.change.addedBranches == ["guard !key.isEmpty"])
        #expect(gap.extendableTests.first == "CoreTests.RecordStoreTests.testSaveThenLoadRoundTrip()")
    }

    @Test func testUntestedSymbolsHaveOnlyMissingBehaviors() throws {
        let (index, _) = Self.scenario()
        let tests = TestIndexer.build(graph: SymbolGraph(index: index))
        let importAll = try #require(index["Core.Importer.importAll(_:)"])
        let change = SymbolChange(symbol: importAll.id, kind: .modified, aspects: [.body], declarationKind: .method, file: importAll.span.file,
                                  role: .production, isInterface: true, isPublicAPI: true)
        let set = ChangeSet(base: "t", files: [], symbols: [change], apiChanges: [], diagnostics: [])
        let gap = try #require(TestGapAnalyzer.analyze(set, index: index, tests: tests).first)
        #expect(!gap.behaviors.isEmpty && gap.behaviors.allSatisfy { $0.status == .missing })
    }

    @Test func testRiskFloorsApplyAndAreExplained() {
        let change = SymbolChange(symbol: "M.Auth.check()", kind: .modified, aspects: [.controlFlow], declarationKind: .method, file: "Sources/M/A.swift",
                                  role: .production, isInterface: true, isPublicAPI: false)
        let auth = RiskClassifier.assess(traits: [TraitEvidence(trait: .authorization, reason: "x")], change: change, directReferrers: 0, hasTests: true)
        #expect(auth.level == .critical)
        #expect(auth.floorRule == "authorization logic or signature changed")

        let plain = RiskClassifier.assess(traits: [TraitEvidence(trait: .pureLogic, reason: "x")], change: change, directReferrers: 0, hasTests: true)
        #expect(plain.level == .low && plain.factors.isEmpty)

        let wide = RiskClassifier.assess(traits: [], change: change, directReferrers: 50, hasTests: false)
        #expect(wide.factors.keys.sorted() == [.wideImpact, .untested])

        let saveRisk = Self.plan().risks["Core.RecordStore.save(_:forKey:)"]
        #expect(saveRisk?.level == .high)
    }

    @Test func testCategoriesWithoutInfrastructureAreSkippedWithAReason() {
        let behavior = RequiredBehavior(id: "view-render", summary: "s", category: .snapshot, trait: .swiftUIView, hints: [], isFailurePath: false, liveRequired: false)
        let live = RequiredBehavior(id: "device-live", summary: "s", category: .endToEnd, trait: .deviceInteraction, hints: [], isFailurePath: false, liveRequired: true)
        let change = SymbolChange(symbol: "M.V.body", kind: .modified, aspects: [.body], declarationKind: .property, file: "f", role: .production, isInterface: true, isPublicAPI: false)
        let gap = SymbolTestGap(symbol: "M.V.body", change: change, traits: [], behaviors: [
            BehaviorCoverage(behavior: behavior, status: .missing, evidence: []), BehaviorCoverage(behavior: live, status: .missing, evidence: []),
        ], extendableTests: [], typeLevelTests: [])
        let conventions = TestConventions(frameworkCounts: ["swiftTesting": 3], dominantFramework: .swiftTesting, targets: ["T"], supportTypes: [], suiteDeclarationStyle: "")
        let selection = TestGapAnalyzer.selectCategories([gap], conventions: conventions)
        #expect(selection.selected.isEmpty)
        #expect(selection.skipped.keys.sorted() == ["endToEnd", "snapshot"])
    }

    @Test func testDraftsAreHumanReadableValidAndBlockedUntilPlaceholdersAreFilled() throws {
        let plan = Self.plan()
        #expect(plan.status == .awaitingRefinement)
        let spec = try #require(plan.specifications.first { $0.behaviorID == "branch-1" })
        #expect(spec.id == "RS-NEG-001")
        #expect(spec.category == .negative && spec.risk == .high)
        #expect(spec.extendsTest == "CoreTests.RecordStoreTests.testSaveThenLoadRoundTrip()")
        #expect(!spec.unresolvedPlaceholders.isEmpty)
        #expect(plan.specIssues.filter { $0.severity == .error }.isEmpty)
        #expect(plan.blocked[spec.id]?.contains { $0.hasPrefix("unresolved placeholder") } ?? false)
        let text = TestSpecificationRenderer.render(spec)
        #expect(text.hasPrefix("TEST RS-NEG-001"))
        #expect(text.contains("Steps:\n1. Arrange state/input for which `guard !key.isEmpty` selects the new path."))
    }

    static func filled(_ spec: TestSpecification) -> TestSpecification {
        var s = spec
        let fill: (String) -> String = { $0.replacingOccurrences(of: TestSpecification.toBeDetermined, with: "filled") }
        s.inputs = s.inputs.map { var i = $0; i.value = fill(i.value); return i }
        s.steps = s.steps.map { st in
            var st = st
            if let args = st.operation?.arguments { st.operation?.arguments = args.mapValues(fill) }
            return st
        }
        s.expectedOutcome = s.expectedOutcome.map { e in
            var e = e
            if let expected = e.assertion?.expected { e.assertion?.expected = fill(expected) }
            return e
        }
        s.openQuestions = []
        return s
    }

    @Test func testAValidRefinementCompilesToAnExecutableInstruction() throws {
        let plan = Self.plan()
        let (index, _) = Self.scenario()
        let draft = try #require(plan.specifications.first)
        let refined = try TestSpecificationValidator.acceptRefinement(Self.filled(draft), of: draft, index: index).get()
        #expect(refined.provenance == .llm && refined.status == .refined)
        let tests = TestIndexer.build(graph: SymbolGraph(index: index))
        guard case .ready(let instruction) = InstructionCompiler.compile(refined, index: index, tests: tests) else {
            Issue.record("expected an executable instruction"); return
        }
        #expect(instruction.framework == .swiftTesting)
        #expect(instruction.suite == "RecordStoreTests")
        #expect(instruction.file == "Tests/CoreTests/RecordStoreTests.swift")
        #expect(instruction.setup.map(\.name) == ["arrangeCondition"])
        #expect(instruction.actions.map(\.name) == ["invoke", "arrangeCondition", "invoke"])
        #expect(instruction.setup.first?.arguments.first { $0.first == "holds" } == ["holds", "true"])
        #expect(instruction.assertions.count == 2)
        #expect(instruction.runner == "swift test --filter RecordStoreTests")
        #expect(!instruction.liveRequired)
    }

    @Test func testRefinementsCannotRetargetLowerRiskDropGatesOrSelfApprove() throws {
        let (index, _) = Self.scenario()
        let draft = try #require(Self.plan().specifications.first)
        func rejected(_ change: (inout TestSpecification) -> Void) -> [String] {
            var s = Self.filled(draft)
            change(&s)
            if case .failure(let r) = TestSpecificationValidator.acceptRefinement(s, of: draft, index: index) { return r.issues.map(\.message) }
            return []
        }
        #expect(rejected { $0.risk = .low }.contains { $0.hasPrefix("risk lowered") })
        #expect(rejected { $0.targetSymbol = "Core.Importer.importAll(_:)" }.contains("target symbol changed"))
        #expect(rejected { $0.status = .approved }.contains("only a human can approve a spec"))
        #expect(rejected { $0.steps[0].operation?.name = "rm -rf" }.contains { $0.contains("is not an identifier") })
        #expect(rejected { $0.purpose = "```swift\nimport XCTest\n```" }.contains("fields must describe behavior, not contain source code"))

        var live = draft
        live.liveRequired = true
        live.approvalRequired = true
        var dropped = Self.filled(live)
        dropped.approvalRequired = false
        guard case .failure(let r) = TestSpecificationValidator.acceptRefinement(dropped, of: live, index: index) else { Issue.record("accepted"); return }
        #expect(r.issues.map(\.message).contains("approval requirement removed"))
    }

    @Test func testModelRepliesAreParsedAndGated() throws {
        let plan = Self.plan()
        let (index, _) = Self.scenario()
        guard case .escalate(let reason) = TestGenerationResponse.parse(#"{"escalate": "need the body of save"}"#, drafts: plan.specifications, index: index) else {
            Issue.record("expected escalation"); return
        }
        #expect(reason == "need the body of save")
        guard case .invalid = TestGenerationResponse.parse("I think the test should...", drafts: plan.specifications, index: index) else {
            Issue.record("expected invalid"); return
        }
        let reply = String(decoding: try JSONEncoder().encode([Self.filled(plan.specifications[0])]), as: UTF8.self)
        guard case .refinements(let accepted, let rejected) = TestGenerationResponse.parse("```json\n\(reply)\n```", drafts: plan.specifications, index: index) else {
            Issue.record("expected refinements"); return
        }
        #expect(accepted.map(\.id) == ["RS-NEG-001"] && rejected.isEmpty)
        let request = TestGenerationRequest.make(plan)
        #expect(request.specIDs == ["RS-NEG-001"])
        #expect(request.user.contains("## Draft specifications (JSON)"))
    }
}
