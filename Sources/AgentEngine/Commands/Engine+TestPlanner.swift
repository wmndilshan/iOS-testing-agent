import Foundation
import CodeIntelligence

/// `--plan-tests`: static change analysis and test planning (CodeIntelligence). Read-only: it never runs tests, calls a
/// model, touches a simulator or reaches the tool registry. It writes only the index cache under `.build/` and, with
/// `--out`, the plan files.
extension Engine {

    static func runTestPlanner(args: [String]) async {
        func value(_ name: String) -> String? { args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) } }
        let root = URL(fileURLWithPath: value("root") ?? FileManager.default.currentDirectoryPath)

        var config = TestPlanningConfiguration()
        config.cacheURL = root.appendingPathComponent(".build/code-intelligence/index-cache.json")
        if let t = value("tier").flatMap(Int.init) {
            guard let tier = ContextTier(rawValue: t) else { print("--tier must be 0...4"); await terminate(1) }
            config.tier = tier
        }
        if let b = value("budget").flatMap(Int.init) { config.budget.maxTokens = b }
        if let d = value("depth").flatMap(Int.init) { config.impact.maxDepth = max(1, d) }
        config.drafting.includeUnverified = args.contains("--include-unverified")

        let source: any ChangeSource
        if let files = value("files") {
            source = ExplicitFilesChangeSource(root: root, paths: files.split(separator: ",").map(String.init))
        } else if let baseline = value("baseline-dir") {
            source = SnapshotChangeSource(root: root, baseline: URL(fileURLWithPath: baseline))
        } else {
            source = GitChangeSource(root: root, base: value("base") ?? "HEAD")
        }

        let plan: TestPlan
        do {
            plan = try TestPlanningPipeline(root: root, configuration: config).run(source: source)
        } catch {
            print("Test planning failed: \(error)")
            await terminate(1)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let specsText = plan.specifications.map(TestSpecificationRenderer.render).joined(separator: "\n\n" + String(repeating: "-", count: 60) + "\n\n")
        if let out = value("out") {
            let dir = URL(fileURLWithPath: out)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try encoder.encode(plan).write(to: dir.appendingPathComponent("plan.json"))
                try encoder.encode(plan.instructions).write(to: dir.appendingPathComponent("instructions.json"))
                try encoder.encode(TestGenerationRequest.make(plan)).write(to: dir.appendingPathComponent("llm-request.json"))
                try plan.contextPack.render().write(to: dir.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
                try specsText.write(to: dir.appendingPathComponent("specs.md"), atomically: true, encoding: .utf8)
            } catch {
                print("Cannot write plan files to \(dir.path): \(error)")
                await terminate(1)
            }
        }
        if args.contains("--format=json") {
            print(String(decoding: (try? encoder.encode(plan)) ?? Data(), as: UTF8.self))
            return
        }

        let c = plan.changeSet
        print("Test plan (\(c.base)): \(plan.status.rawValue)")
        print("  changes:   \(c.files.count) file(s), \(c.productionSymbols.count) production symbol(s), \(c.apiChanges.count) interface signature change(s)")
        print("  risk:      \(plan.overallRisk.level.rawValue)" + (plan.overallRisk.floorRule.map { " (\($0))" } ?? ""))
        print("  impact:    \(plan.impact.slices.map(\.nodes.count).reduce(0, +)) caller(s), \(plan.testsToRun.count) existing test(s) to run")
        print("  gaps:      \(plan.gaps.flatMap(\.missing).count) missing behavior(s); categories: \(plan.categories.selected.map(\.rawValue).joined(separator: ", "))")
        print("  skills:    \(plan.skills.applied.map(\.name).joined(separator: ", "))" + (plan.skills.requiresResolution ? "  [UNRESOLVED CONFLICT]" : ""))
        print("  context:   tier \(plan.contextPack.tier.rawValue), ~\(plan.contextPack.estimatedTokens) tokens (budget \(plan.contextPack.budget.maxTokens))")
        print("  specs:     \(plan.specifications.count) drafted, \(plan.instructions.count) executable, \(plan.blocked.count) awaiting refinement")
        print("  index:     \(plan.indexStatistics.files) files (\(plan.indexStatistics.reusedFromCache) cached), \(plan.indexStatistics.declarations) declarations")
        for d in c.diagnostics { print("  note: \(d)") }
        if !specsText.isEmpty { print("\n" + specsText) }
    }
}
