import Foundation

/// How much context the model receives. Each tier includes everything below it.
public enum ContextTier: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Change summary, symbol IDs, risk and category decisions.
    case metadata = 0
    /// + signatures, AST facts, traits, missing behaviors, skill instructions.
    case signatures = 1
    /// + callers (impact slice) and existing tests / conventions.
    case neighborhood = 2
    /// + minimal source slices of the changed declarations and one existing-test pattern.
    case sourceSlices = 3
    /// + full changed production files. Never chosen by default; only on explicit escalation.
    case fullFiles = 4

    public static func < (a: ContextTier, b: ContextTier) -> Bool { a.rawValue < b.rawValue }
}

public struct ContextBudget: Codable, Sendable {
    /// Estimated tokens (UTF-8 bytes / 4) the rendered pack may use.
    public var maxTokens = 6_000
    public var maxSnippetLines = 40
    public var maxCallersPerSymbol = 8
    public var maxTestsPerSymbol = 5
    public var maxSkillSectionCharacters = 1_200
    public var maxChangedSymbols = 25
    public init() {}
    public init(maxTokens: Int) { self.maxTokens = maxTokens }
}

public struct PackSymbol: Codable, Sendable {
    public var id: SymbolID
    public var kind: String
    public var change: String
    public var aspects: [String]
    public var location: String
    public var signature: String?
    public var oldSignature: String?
    public var facts: String?
    public var traits: [String]
    public var risk: String?
}

public struct PackCaller: Codable, Sendable {
    public var symbol: SymbolID
    public var impact: ImpactClass
    public var path: String
    public var signature: String?
}

public struct PackTest: Codable, Sendable {
    public var id: SymbolID
    public var name: String
    public var framework: String
    public var location: String
    public var assertions: Int
    public var mocks: [String]
    public var fixtures: [String]
}

public struct PackSnippet: Codable, Sendable {
    public var file: String
    public var lines: String
    public var reason: String
    public var text: String
}

public struct PackSkillSection: Codable, Sendable {
    public var skill: String
    public var scope: SkillScope
    public var heading: String
    public var body: String
}

public struct PackGap: Codable, Sendable {
    public var symbol: SymbolID
    public var behavior: String
    public var category: TestCategory
    public var status: CoverageStatus
}

public struct EscalationAdvice: Codable, Sendable {
    public var nextTier: ContextTier
    public var reasons: [String]
}

/// The smallest useful context for test planning and generation. Built from index facts; source text only as bounded,
/// redacted slices from tier 3 on.
public struct ContextPack: Codable, Sendable {
    public var tier: ContextTier
    public var tierReasons: [String]
    public var budget: ContextBudget
    public var estimatedTokens: Int
    public var changeSummary: String
    public var files: [String]
    public var changedSymbols: [PackSymbol]
    public var callers: [SymbolID: [PackCaller]]
    public var tests: [SymbolID: [PackTest]]
    public var testConventions: String?
    public var testPatterns: [PackSnippet]
    public var skills: [PackSkillSection]
    public var skillConflicts: [String]
    public var riskLevel: RiskLevel
    public var riskFactors: [String]
    public var gaps: [PackGap]
    public var selectedCategories: [TestCategory]
    public var skippedCategories: [String: String]
    public var snippets: [PackSnippet]
    /// What was left out to fit the budget or the tier, and why. The model is told about omissions.
    public var omissions: [String]
    public var escalation: EscalationAdvice?

    /// Compact text actually sent to the model.
    public func render() -> String {
        var o: [String] = []
        o.append("# Change context (tier \(tier.rawValue): \(tier))")
        o.append(changeSummary)
        o.append("Risk: \(riskLevel.rawValue)" + (riskFactors.isEmpty ? "" : " — " + riskFactors.joined(separator: "; ")))
        o.append("Test categories: " + (selectedCategories.isEmpty ? "none required" : selectedCategories.map(\.rawValue).joined(separator: ", "))
                 + (skippedCategories.isEmpty ? "" : " (skipped: " + skippedCategories.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ") + ")"))
        if !files.isEmpty { o.append("Files: " + files.joined(separator: ", ")) }
        if !changedSymbols.isEmpty {
            o.append("\n## Changed symbols")
            for s in changedSymbols {
                o.append("- \(s.id) [\(s.kind), \(s.change): \(s.aspects.joined(separator: ","))] \(s.location)" + (s.risk.map { " risk=\($0)" } ?? ""))
                if let old = s.oldSignature, old != s.signature { o.append("  before: \(old)") }
                if let sig = s.signature { o.append("  sig: \(sig)") }
                if let f = s.facts { o.append("  facts: \(f)") }
                if !s.traits.isEmpty { o.append("  traits: \(s.traits.joined(separator: "; "))") }
            }
        }
        if !gaps.isEmpty {
            o.append("\n## Required behaviors (static heuristics)")
            for g in gaps { o.append("- [\(g.status.rawValue)] \(g.symbol.leaf): \(g.behavior) (\(g.category.rawValue))") }
        }
        if !callers.isEmpty {
            o.append("\n## Callers")
            for (sym, cs) in callers.sorted(by: { $0.key < $1.key }) {
                o.append("- \(sym.leaf):")
                for c in cs { o.append("  - [\(c.impact.rawValue)] \(c.path)" + (c.signature.map { "  sig: \($0)" } ?? "")) }
            }
        }
        if !tests.isEmpty {
            o.append("\n## Existing tests")
            for (sym, ts) in tests.sorted(by: { $0.key < $1.key }) {
                o.append("- \(sym.leaf):")
                for t in ts {
                    o.append("  - \(t.name) (\(t.framework), \(t.location), \(t.assertions) assertions" + (t.mocks.isEmpty ? "" : ", mocks: \(t.mocks.joined(separator: ","))")
                             + (t.fixtures.isEmpty ? "" : ", fixtures: \(t.fixtures.joined(separator: ","))") + ")")
                }
            }
        }
        if let c = testConventions { o.append("\n## Test conventions\n\(c)") }
        if !skills.isEmpty {
            o.append("\n## Testing instructions (SKILL.md, highest precedence first)")
            for s in skills { o.append("### \(s.skill) [\(s.scope.rawValue)] — \(s.heading)\n\(s.body)") }
        }
        if !skillConflicts.isEmpty { o.append("\n## Skill conflicts\n" + skillConflicts.map { "- \($0)" }.joined(separator: "\n")) }
        for (title, list) in [("Source slices", snippets), ("Existing test pattern", testPatterns)] where !list.isEmpty {
            o.append("\n## \(title)")
            for s in list { o.append("// \(s.file):\(s.lines) — \(s.reason)\n\(s.text)") }
        }
        if !omissions.isEmpty { o.append("\n## Omitted (ask for escalation if needed)\n" + omissions.map { "- \($0)" }.joined(separator: "\n")) }
        return o.joined(separator: "\n")
    }

    /// Rough, deterministic estimate (UTF-8 bytes / 4), adequate for budgeting.
    public static func estimateTokens(_ text: String) -> Int { (text.utf8.count + 3) / 4 }
}
