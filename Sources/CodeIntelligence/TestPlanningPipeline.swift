import Foundation

public struct TestPlanningConfiguration: Sendable {
    public var impact = ImpactConfiguration()
    public var budget = ContextBudget()
    /// Force a context tier; nil lets the builder choose the smallest sufficient one.
    public var tier: ContextTier?
    public var drafting = TestSpecificationDrafter.Options()
    /// Per-file index cache (content-hash keyed). Nil disables caching.
    public var cacheURL: URL?
    public init() {}
}

public enum PlanStatus: String, Codable, Sendable {
    /// Nothing in production changed that needs a new test (docs, tests only, or all behaviors covered).
    case noNewTestsRequired
    /// Drafts exist; expected values/inputs must be filled by the LLM (or a human) before compilation.
    case awaitingRefinement
    /// Every spec compiled to an executable instruction.
    case ready
    /// Applicable SKILL.md files conflict at the same precedence; a human must resolve this first.
    case blockedOnSkillConflict
}

/// The auditable output of one planning run. Deterministic for the same repository state and configuration
/// (except `timingsMilliseconds`).
public struct TestPlan: Codable, Sendable {
    public var status: PlanStatus
    public var changeSet: ChangeSet
    public var impact: ImpactReport
    public var gaps: [SymbolTestGap]
    public var risks: [SymbolID: RiskAssessment]
    public var overallRisk: RiskAssessment
    public var categories: CategorySelection
    public var skills: SkillResolution
    public var contextPack: ContextPack
    public var specifications: [TestSpecification]
    public var specIssues: [SpecIssue]
    public var instructions: [ExecutableTestInstruction]
    /// Spec ID -> why it cannot compile yet.
    public var blocked: [String: [String]]
    /// Existing tests to run for this change (impacted tests plus changed tests).
    public var testsToRun: [SymbolID]
    public var indexStatistics: RepositoryScanner.Statistics
    public var graphStatistics: SymbolGraph.Statistics
    public var timingsMilliseconds: [String: Int]
}

/// Git diff -> ChangeSet -> AST index -> symbol graph -> impact -> test index -> gaps -> risk -> skills -> ContextPack
/// -> TestSpecification drafts -> ExecutableTestInstructions. No model is called here; see `TestGenerationRequest`.
public struct TestPlanningPipeline: Sendable {
    public let root: URL
    public var configuration: TestPlanningConfiguration

    public init(root: URL, configuration: TestPlanningConfiguration = .init()) {
        self.root = root.standardizedFileURL
        self.configuration = configuration
    }

    public func run(source: some ChangeSource) throws -> TestPlan {
        var timings: [String: Int] = [:]
        func timed<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer { timings[label] = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
            return try work()
        }
        let raw = try timed("changes") { try source.changes() }
        let changes = timed("diff") { ChangeAnalyzer.analyze(raw, base: source.baseDescription) }
        let needsIndex = changes.files.contains { $0.path.hasSuffix(".swift") }
        let (index, indexStats) = timed("index") {
            needsIndex ? RepositoryScanner(root: root).buildIndex(cacheURL: configuration.cacheURL) : (ASTIndex(), RepositoryScanner.Statistics())
        }
        let discovered = timed("skills.discover") { SkillResolver.discover(root: root) }
        var plan = plan(changes: changes, index: index, skills: discovered.skills, skillErrors: discovered.errors, timings: &timings)
        plan.indexStatistics = indexStats
        return plan
    }

    /// The pure part of the pipeline (no file-system scanning), used by `run` and directly by tests.
    public func plan(changes: ChangeSet, index: ASTIndex, skills: [TestingSkill], skillErrors: [String] = [], timings: inout [String: Int]) -> TestPlan {
        func timed<T>(_ label: String, _ work: () -> T) -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer { timings[label] = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
            return work()
        }
        let graph = timed("graph") { SymbolGraph(index: index) }
        let impact = timed("impact") { ImpactAnalyzer.analyze(changes, graph: graph, configuration: configuration.impact) }
        let tests = timed("tests") { TestIndexer.build(graph: graph) }
        let gaps = timed("gaps") { TestGapAnalyzer.analyze(changes, index: index, tests: tests) }

        let slices = Dictionary(impact.slices.map { ($0.changed, $0) }, uniquingKeysWith: { a, _ in a })
        let gapTraits = Dictionary(gaps.map { ($0.symbol, $0.traits) }, uniquingKeysWith: { a, _ in a })
        var risks: [SymbolID: RiskAssessment] = [:]
        for c in changes.productionSymbols {
            let traits = gapTraits[c.symbol] ?? index[c.symbol].map { TraitDetector.detect($0, change: c, index: index) } ?? []
            let direct = slices[c.symbol]?.nodes.filter { $0.impact == .direct }.count ?? 0
            let hasTests = !(tests.bySymbol[c.symbol] ?? []).isEmpty || !(slices[c.symbol]?.tests.isEmpty ?? true)
            risks[c.symbol] = RiskClassifier.assess(traits: traits, change: c, directReferrers: direct, hasTests: hasTests)
        }
        let overall = RiskClassifier.overall(risks.sorted { $0.key < $1.key }.map(\.value), changes: changes)
        let categories = TestGapAnalyzer.selectCategories(gaps, conventions: tests.conventions)

        let changedFiles = changes.files.map(\.path)
        let imports = Set(changedFiles.flatMap { index.files[$0]?.imports ?? [] })
        let traits = Set(gaps.flatMap { $0.traits.map(\.trait) })
        let names = Set(changes.symbols.flatMap { c -> [String] in
            [index[c.symbol]?.name, c.symbol.rawValue.split(separator: ".").dropFirst().first.map(String.init)].compactMap { $0 }
        })
        let context = SkillContext(paths: changedFiles, modules: Set(changes.files.map(\.module)), symbolNames: names,
                                   technologies: SkillResolver.technologies(imports: imports, traits: traits),
                                   categories: Set(categories.selected), traits: traits)
        let skillResolution = timed("skills.resolve") { SkillResolver.resolve(skills, context: context, parseErrors: skillErrors) }

        let root = self.root
        let inputs = ContextInputs(changes: changes, impact: impact, gaps: gaps, risks: risks, overallRisk: overall, categories: categories,
                                   skills: skillResolution, index: index, tests: tests,
                                   readFile: { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) })
        let pack = timed("context") { ContextPackBuilder.build(inputs, tier: configuration.tier, budget: configuration.budget) }

        let specs = timed("specs") { TestSpecificationDrafter.draft(gaps: gaps, risks: risks, index: index, tests: tests, options: configuration.drafting) }
        let issues = specs.flatMap { TestSpecificationValidator.validate($0, index: index) }
        let framework = skillResolution.effectiveDirectives["framework"].flatMap(Self.framework)
        var instructions: [ExecutableTestInstruction] = []
        var blocked: [String: [String]] = [:]
        if skillResolution.requiresResolution {
            for s in specs { blocked[s.id] = ["unresolved SKILL.md conflict"] }
        } else {
            for s in specs {
                switch InstructionCompiler.compile(s, index: index, tests: tests, framework: framework) {
                case .ready(let i): instructions.append(i)
                case .blocked(let id, let reasons): blocked[id] = reasons
                }
            }
        }
        let changedTests = changes.symbols.filter { $0.role == .test && $0.kind != .removed }.map(\.symbol).filter { tests.tests[$0] != nil }
        let status: PlanStatus = skillResolution.requiresResolution ? .blockedOnSkillConflict
            : specs.isEmpty ? .noNewTestsRequired : (blocked.isEmpty ? .ready : .awaitingRefinement)
        return TestPlan(status: status, changeSet: changes, impact: impact, gaps: gaps, risks: risks, overallRisk: overall, categories: categories,
                        skills: skillResolution, contextPack: pack, specifications: specs, specIssues: issues, instructions: instructions,
                        blocked: blocked, testsToRun: Array(Set(impact.allTests + changedTests)).sorted(),
                        indexStatistics: RepositoryScanner.Statistics(), graphStatistics: graph.statistics, timingsMilliseconds: timings)
    }

    static func framework(_ directive: String) -> TestFramework? {
        switch directive.lowercased() {
        case "swift-testing", "swifttesting", "testing": .swiftTesting
        case "xctest": .xctest
        default: nil
        }
    }
}
