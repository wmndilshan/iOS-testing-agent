import Testing
import Foundation
@testable import CodeIntelligence

@Suite("Code intelligence: SKILL.md resolution and context packs")
struct SkillsAndContextTests {
    typealias F = CodeIntelligenceFixtures

    static func skill(_ name: String, scope: SkillScope, applies: String = "", directives: String = "", body: String = "## Rules\nDo the thing.") -> String {
        """
        ---
        name: \(name)
        description: d
        scope: \(scope.rawValue)
        \(applies.isEmpty ? "" : "applies-to:\n" + applies)
        \(directives.isEmpty ? "" : "directives:\n" + directives)
        ---
        \(body)
        """
    }

    static let context = SkillContext(paths: ["Sources/Core/RecordStore.swift"], modules: ["Core"], symbolNames: ["RecordStore", "save"],
                                      technologies: ["swift", "swift-concurrency"], categories: [.negative], traits: [.throwing, .concurrency])

    @Test func testFrontmatterListsDirectivesAndConditionalSectionsParse() throws {
        let text = Self.skill("s", scope: .module, applies: "  paths: [Sources/Core/**]\n  symbols:\n    - RecordStore", directives: "  framework: swift-testing",
                              body: "## Always\nA.\n## Only for concurrency\n<!-- when: categories=concurrency; traits=async -->\nB.")
        let s = try SkillParser.parse(text, path: "x/SKILL.md")
        #expect(s.scope == .module)
        #expect(s.appliesTo.paths == ["Sources/Core/**"] && s.appliesTo.symbols == ["RecordStore"])
        #expect(s.directives == ["framework": "swift-testing"])
        #expect(s.sections.map(\.heading) == ["Always", "Only for concurrency"])
        #expect(s.sections[1].when?.categories == ["concurrency"] && s.sections[1].when?.traits == ["async"])
        #expect(s.sections[1].body == "B.")
        #expect(throws: SkillParseError.missingFrontmatter("y")) { try SkillParser.parse("# no frontmatter", path: "y") }
        #expect(throws: SkillParseError.invalidScope("z", value: "global")) { try SkillParser.parse("---\nname: z\nscope: global\n---", path: "z") }
    }

    @Test func testOnlyApplicableSkillsAndSectionsAreSelectedInPrecedenceOrder() throws {
        let skills = try [
            SkillParser.parse(Self.skill("generic", scope: .generic, applies: "  technologies: [swift]"), path: "g"),
            SkillParser.parse(Self.skill("ui", scope: .technology, applies: "  technologies: [swiftui]"), path: "u"),
            SkillParser.parse(Self.skill("core", scope: .module, applies: "  paths: [Sources/Core/**]",
                                         body: "## Core\nC.\n## Persistence only\n<!-- when: categories=persistence -->\nP."), path: "c"),
            SkillParser.parse(Self.skill("project", scope: .project), path: "p"),
        ]
        let r = SkillResolver.resolve(skills, context: Self.context)
        #expect(r.applied.map(\.name) == ["project", "core", "generic"])
        #expect(r.omitted.keys.sorted() == ["ui"])
        let core = try #require(r.applied.first { $0.name == "core" })
        #expect(core.matchedBy == ["path Sources/Core/**"])
        #expect(core.sections.map(\.heading) == ["Core"] && core.omittedSections == ["Persistence only"])
    }

    @Test func testConflictingDirectivesResolveByPrecedenceOrRequireAHuman() throws {
        let project = try SkillParser.parse(Self.skill("project", scope: .project, directives: "  framework: swift-testing"), path: "p")
        let module = try SkillParser.parse(Self.skill("core", scope: .module, applies: "  modules: [Core]", directives: "  framework: xctest"), path: "c")
        let resolved = SkillResolver.resolve([project, module], context: Self.context)
        #expect(resolved.effectiveDirectives["framework"] == "swift-testing")
        #expect(resolved.conflicts.first?.resolution == .precedence(winner: "project"))
        #expect(!resolved.requiresResolution)

        let other = try SkillParser.parse(Self.skill("core2", scope: .module, applies: "  modules: [Core]", directives: "  framework: swift-testing"), path: "c2")
        let clash = SkillResolver.resolve([module, other], context: Self.context)
        #expect(clash.requiresResolution)
        #expect(clash.effectiveDirectives["framework"] == nil, "an unresolved directive is never silently merged")
        #expect(clash.conflicts.first?.values == ["core": "xctest", "core2": "swift-testing"])
    }

    @Test func testAnUnresolvedSkillConflictBlocksEveryInstruction() throws {
        let a = try SkillParser.parse(Self.skill("a", scope: .project, directives: "  framework: xctest"), path: "a")
        let b = try SkillParser.parse(Self.skill("b", scope: .project, directives: "  framework: swift-testing"), path: "b")
        let plan = TestPlanningTests.plan(skills: [a, b])
        #expect(plan.status == .blockedOnSkillConflict)
        #expect(plan.instructions.isEmpty)
        #expect(plan.blocked.values.allSatisfy { $0 == ["unresolved SKILL.md conflict"] })
        #expect(plan.contextPack.render().contains("UNRESOLVED (a human must decide)"))
    }

    @Test func testGlobsMatchPathComponents() {
        #expect(Glob.matches("Sources/**/Workflow/*.swift", "Sources/AgentCore/Application/Workflow/WorkflowScheduler.swift"))
        #expect(Glob.matches("Sources/**", "Sources/A/B.swift"))
        #expect(!Glob.matches("Sources/*.swift", "Sources/A/B.swift"))
        #expect(!Glob.matches("Tests/**", "Sources/Tests/A.swift"))
    }

    @Test func testTheRepositorySkillsParseWithoutErrors() {
        let found = SkillResolver.discover(root: RepositoryRoot.url)
        #expect(found.errors.isEmpty, "\(found.errors)")
        #expect(found.skills.contains { $0.name == "project-testing" && $0.scope == .project })
    }

    // MARK: Context pack

    static func inputs(budget: ContextBudget = .init()) -> (ContextInputs, TestPlan) {
        let plan = TestPlanningTests.plan()
        let (index, _) = TestPlanningTests.scenario()
        let tests = TestIndexer.build(graph: SymbolGraph(index: index))
        let sources = F.package.merging([TestPlanningTests.savePath: TestPlanningTests.changedStore]) { _, b in b }
        let i = ContextInputs(changes: plan.changeSet, impact: plan.impact, gaps: plan.gaps, risks: plan.risks, overallRisk: plan.overallRisk,
                              categories: plan.categories, skills: plan.skills, index: index, tests: tests, readFile: { sources[$0] })
        return (i, plan)
    }

    @Test func testTheSmallestSufficientTierIsChosenWithReasons() {
        let (i, _) = Self.inputs()
        let (tier, reasons) = ContextPackBuilder.recommendedTier(i)
        #expect(tier == .sourceSlices, "HIGH risk logic change")
        #expect(reasons.first?.contains("save(_:forKey:)") ?? false)

        var docs = i
        docs.changes = ChangeAnalyzer.analyze([RawFileChange(path: "docs/A.md", status: .modified, oldText: "a", newText: "b")], base: "t")
        #expect(ContextPackBuilder.recommendedTier(docs).0 == .metadata)
    }

    @Test func testTiersAddContentMonotonicallyAndNeverIncludeWholeFilesByDefault() {
        let (i, _) = Self.inputs()
        let t1 = ContextPackBuilder.build(i, tier: .signatures)
        let t2 = ContextPackBuilder.build(i, tier: .neighborhood)
        let t3 = ContextPackBuilder.build(i)
        #expect(t1.callers.isEmpty && t1.tests.isEmpty && t1.snippets.isEmpty)
        #expect(!t2.tests.isEmpty && t2.snippets.isEmpty)
        #expect(t3.tier == .sourceSlices && t3.snippets.count == 1)
        #expect(t3.snippets[0].text.contains("guard !key.isEmpty"))
        #expect(!t3.snippets[0].text.contains("public func load"), "a slice of the changed declaration, not the file")
        #expect(t1.estimatedTokens < t2.estimatedTokens && t2.estimatedTokens < t3.estimatedTokens)
        #expect(t3.escalation?.nextTier == .fullFiles)
    }

    @Test func testTheBudgetIsEnforcedAndOmissionsAreRecorded() {
        let (i, _) = Self.inputs()
        let full = ContextPackBuilder.build(i)
        let tight = ContextPackBuilder.build(i, budget: ContextBudget(maxTokens: full.estimatedTokens - 60))
        #expect(tight.estimatedTokens <= tight.budget.maxTokens)
        #expect(!tight.omissions.isEmpty)
        #expect(tight.render().contains("## Omitted (ask for escalation if needed)"))

        let tiny = ContextPackBuilder.build(i, budget: ContextBudget(maxTokens: 50))
        #expect(tiny.tier == .metadata, "falls back tier by tier")
        #expect(tiny.omissions.contains { $0.contains("fell back to tier") })
    }

    @Test func testEscalationMovesUpOneTierWithTheReason() throws {
        let (i, _) = Self.inputs()
        let pack = ContextPackBuilder.build(i, tier: .neighborhood)
        let up = try #require(ContextPackBuilder.escalate(pack, inputs: i, reason: "need the body"))
        #expect(up.tier == .sourceSlices && up.tierReasons.first == "escalated: need the body")
        let top = ContextPackBuilder.build(i, tier: .fullFiles, budget: ContextBudget(maxTokens: 100_000))
        #expect(ContextPackBuilder.escalate(top, inputs: i, reason: "x") == nil)
    }

    @Test func testCredentialLookingLiteralsAreRedactedFromSlices() {
        let key = "AIza" + String(repeating: "B", count: 35)
        let src = "let k = \"\(key)\"\nlet t = \"Bearer abcdefghijklmnopqrstuvwxyz\""
        let out = SnippetRedactor.redact(src)
        #expect(!out.contains(key) && !out.contains("abcdefghijklmnop"))
        #expect(out.components(separatedBy: "<REDACTED>").count == 3)
    }

    @Test func testAPlanIsDeterministicForTheSameInputs() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func stable(_ p: TestPlan) throws -> Data { var p = p; p.timingsMilliseconds = [:]; return try encoder.encode(p) }
        #expect(try stable(TestPlanningTests.plan()) == stable(TestPlanningTests.plan()))
    }
}
