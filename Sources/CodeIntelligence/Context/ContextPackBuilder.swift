import Foundation

/// Everything the builder may draw from. Assembled by `TestPlanningPipeline`.
public struct ContextInputs: Sendable {
    public var changes: ChangeSet
    public var impact: ImpactReport
    public var gaps: [SymbolTestGap]
    public var risks: [SymbolID: RiskAssessment]
    public var overallRisk: RiskAssessment
    public var categories: CategorySelection
    public var skills: SkillResolution
    public var index: ASTIndex
    public var tests: TestIndex
    /// Reads a repository-relative file (working tree). Only called from tier 3 on.
    public var readFile: @Sendable (String) -> String?
}

public enum ContextPackBuilder {

    /// Smallest tier expected to be sufficient, with the reasons. Tier 4 is never recommended.
    public static func recommendedTier(_ i: ContextInputs) -> (ContextTier, [String]) {
        let production = i.changes.productionSymbols
        if production.isEmpty {
            return (.metadata, [i.changes.isDocumentationOnly ? "documentation-only change" : (i.changes.isTestOnly ? "test-only change" : "no production symbol changed")])
        }
        var reasons: [String] = []
        let logicAspects: Set<ChangeAspect> = [.body, .controlFlow, .errorHandling, .stateMutation, .concurrency, .declarationAdded]
        let needsSource = i.gaps.filter { gap in
            let risky = (i.risks[gap.symbol]?.level ?? .low) >= .high
            let logic = !Set(gap.change.aspects).isDisjoint(with: logicAspects)
            let new = gap.change.kind == .added && !gap.missing.isEmpty
            return (risky && logic) || new
        }
        if !needsSource.isEmpty {
            reasons.append("logic changed in HIGH/CRITICAL or new symbols: " + needsSource.prefix(3).map { $0.symbol.leaf }.joined(separator: ", "))
            return (.sourceSlices, reasons)
        }
        if production.allSatisfy({ Set($0.aspects).isDisjoint(with: logicAspects) }) {
            return (.signatures, ["only signatures/attributes changed"])
        }
        return (.neighborhood, ["logic changed in LOW/MEDIUM symbols; callers and existing tests are needed"])
    }

    public static func build(_ i: ContextInputs, tier requested: ContextTier? = nil, budget: ContextBudget = .init()) -> ContextPack {
        let (recommended, reasons) = recommendedTier(i)
        let tier = requested ?? recommended
        var pack = assemble(i, tier: tier, budget: budget, reasons: requested == nil ? reasons : ["requested tier \(tier.rawValue)"] + reasons)
        fit(&pack, budget: budget)
        if pack.estimatedTokens > budget.maxTokens, tier > .metadata, let lower = ContextTier(rawValue: tier.rawValue - 1) {
            var smaller = build(i, tier: lower, budget: budget)
            smaller.omissions.insert("tier \(tier.rawValue) did not fit \(budget.maxTokens) tokens; fell back to tier \(lower.rawValue)", at: 0)
            smaller.estimatedTokens = ContextPack.estimateTokens(smaller.render())
            return smaller
        }
        if tier < .fullFiles {
            pack.escalation = EscalationAdvice(nextTier: ContextTier(rawValue: tier.rawValue + 1)!, reasons: [escalationHint(tier)])
        }
        return pack
    }

    /// The next tier, when the model (or a reviewer) reports insufficient context. Nil at tier 4.
    public static func escalate(_ pack: ContextPack, inputs: ContextInputs, reason: String) -> ContextPack? {
        guard let next = ContextTier(rawValue: pack.tier.rawValue + 1) else { return nil }
        var p = build(inputs, tier: next, budget: pack.budget)
        p.tierReasons.insert("escalated: \(reason)", at: 0)
        return p
    }

    private static func escalationHint(_ tier: ContextTier) -> String {
        switch tier {
        case .metadata: "signatures and AST facts"
        case .signatures: "callers and existing tests"
        case .neighborhood: "source slices of the changed declarations"
        case .sourceSlices: "full changed files"
        case .fullFiles: ""
        }
    }

    // MARK: Assembly

    static func assemble(_ i: ContextInputs, tier: ContextTier, budget: ContextBudget, reasons: [String]) -> ContextPack {
        let production = i.changes.productionSymbols
        let apiCount = i.changes.apiChanges.count
        let summary = "\(i.changes.files.count) file(s), \(production.count) production symbol change(s) (\(apiCount) interface signature change(s)), "
            + "\(i.changes.symbols.count - production.count) test/other; base \(i.changes.base)"
        let gapBySymbol = Dictionary(i.gaps.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        var omissions: [String] = []

        let ranked = production.sorted { a, b in
            let ra = i.risks[a.symbol]?.level ?? .low, rb = i.risks[b.symbol]?.level ?? .low
            return ra != rb ? ra > rb : a.symbol < b.symbol
        }
        if ranked.count > budget.maxChangedSymbols { omissions.append("\(ranked.count - budget.maxChangedSymbols) lower-risk changed symbol(s)") }
        let shown = Array(ranked.prefix(budget.maxChangedSymbols))

        let symbols = shown.map { c -> PackSymbol in
            let d = i.index[c.symbol]
            let detailed = tier >= .signatures
            return PackSymbol(id: c.symbol, kind: c.declarationKind.rawValue, change: c.kind.rawValue, aspects: c.aspects.map(\.rawValue),
                              location: d.map { "\($0.span.file):\($0.span.line)" } ?? c.file,
                              signature: detailed ? (c.newSignature ?? c.oldSignature) : nil, oldSignature: detailed ? c.oldSignature : nil,
                              facts: detailed ? d.flatMap(facts) : nil,
                              traits: detailed ? (gapBySymbol[c.symbol]?.traits.map { "\($0.trait.rawValue) (\($0.reason))" } ?? []) : [],
                              risk: i.risks[c.symbol]?.level.rawValue)
        }
        let gaps: [PackGap] = tier >= .signatures ? i.gaps.flatMap { g in
            g.behaviors.filter { $0.status != .covered }.map { PackGap(symbol: g.symbol, behavior: $0.behavior.summary, category: $0.behavior.category, status: $0.status) }
        } : []

        var callers: [SymbolID: [PackCaller]] = [:]
        var tests: [SymbolID: [PackTest]] = [:]
        var conventions: String?
        if tier >= .neighborhood {
            for slice in i.impact.slices where shown.contains(where: { $0.symbol == slice.changed }) {
                let nodes = slice.nodes.prefix(budget.maxCallersPerSymbol)
                if slice.nodes.count > nodes.count || slice.truncated { omissions.append("\(slice.changed.leaf): further callers beyond \(nodes.count) shown") }
                callers[slice.changed] = nodes.map { n in
                    PackCaller(symbol: n.symbol, impact: n.impact, path: slice.path(to: n.symbol).map(\.leaf).joined(separator: " <- "),
                               signature: n.impact == .direct ? i.index[n.symbol]?.signature : nil)
                }
                let related = Array(Set(slice.tests + (gapBySymbol[slice.changed]?.extendableTests ?? []))).sorted()
                let ts = related.compactMap { i.tests.tests[$0] }.sorted { ($0.referencedSymbols.count, $0.id) < ($1.referencedSymbols.count, $1.id) }
                if ts.count > budget.maxTestsPerSymbol { omissions.append("\(slice.changed.leaf): \(ts.count - budget.maxTestsPerSymbol) more related test(s)") }
                if !ts.isEmpty {
                    tests[slice.changed] = ts.prefix(budget.maxTestsPerSymbol).map { t in
                        PackTest(id: t.id, name: t.displayName.map { "\(t.name) — \($0)" } ?? t.name,
                                 framework: t.framework.rawValue, location: "\(t.span.file):\(t.span.line)", assertions: t.assertionCount,
                                 mocks: t.mocks, fixtures: t.fixtures)
                    }
                }
            }
            let c = i.tests.conventions
            conventions = "Framework: \(c.dominantFramework.rawValue) (\(c.frameworkCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))). "
                + "Style: \(c.suiteDeclarationStyle). Shared fakes/fixtures: \(c.supportTypes.prefix(20).joined(separator: ", "))."
        }

        let skillSections: [PackSkillSection] = tier >= .signatures ? i.skills.applied.flatMap { s in
            s.sections.map { PackSkillSection(skill: s.name, scope: s.scope, heading: $0.heading, body: String($0.body.prefix(budget.maxSkillSectionCharacters))) }
        } : []
        let conflicts = i.skills.conflicts.map { c -> String in
            let values = c.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            switch c.resolution {
            case .precedence(let w): return "\(c.directive): \(values) -> \(w) wins by precedence"
            case .unresolved: return "\(c.directive): \(values) -> UNRESOLVED (a human must decide)"
            }
        }

        var snippets: [PackSnippet] = []
        var patterns: [PackSnippet] = []
        if tier >= .sourceSlices {
            let changedLines = Dictionary(i.changes.files.map { ($0.path, $0.changedLines) }, uniquingKeysWith: { a, _ in a })
            for c in shown where c.kind != .removed {
                guard let d = i.index[c.symbol], d.kind.isCallable || d.kind == .property, let text = i.readFile(d.span.file) else { continue }
                if let s = slice(text, d.span, changed: changedLines[d.span.file] ?? nil, maxLines: budget.maxSnippetLines) {
                    snippets.append(PackSnippet(file: d.span.file, lines: s.lines, reason: "changed \(c.symbol.leaf)", text: s.text))
                }
            }
            if let testID = i.gaps.lazy.compactMap({ $0.extendableTests.first }).first, let t = i.tests.tests[testID], let text = i.readFile(t.span.file),
               let s = slice(text, t.span, changed: nil, maxLines: 25) {
                patterns.append(PackSnippet(file: t.span.file, lines: s.lines, reason: "existing test to follow/extend", text: s.text))
            }
        }
        if tier >= .fullFiles {
            for path in Set(shown.map(\.file)).sorted() where RepositoryScanner.classify(path).role == .production {
                if let text = i.readFile(path) { snippets.append(PackSnippet(file: path, lines: "all", reason: "full file (tier 4)", text: SnippetRedactor.redact(text))) }
            }
        }

        var pack = ContextPack(
            tier: tier, tierReasons: reasons, budget: budget, estimatedTokens: 0, changeSummary: summary,
            files: i.changes.files.map { "\($0.path) (\($0.status.rawValue))" }, changedSymbols: symbols,
            callers: callers, tests: tests, testConventions: conventions, testPatterns: patterns, skills: skillSections, skillConflicts: conflicts,
            riskLevel: i.overallRisk.level, riskFactors: i.overallRisk.factors.sorted { $0.key < $1.key }.map { "\($0.key.rawValue): \($0.value)" },
            gaps: gaps, selectedCategories: i.categories.selected, skippedCategories: i.categories.skipped,
            snippets: snippets, omissions: omissions, escalation: nil)
        pack.estimatedTokens = ContextPack.estimateTokens(pack.render())
        return pack
    }

    /// Deterministic reduction order: least useful first. Each step is recorded in `omissions`.
    static func fit(_ pack: inout ContextPack, budget: ContextBudget) {
        func over() -> Bool {
            pack.estimatedTokens = ContextPack.estimateTokens(pack.render())
            return pack.estimatedTokens > budget.maxTokens
        }
        guard over() else { return }
        let steps: [(String, (inout ContextPack) -> Bool)] = [
            ("transitive callers", { p in
                let before = p.callers.values.map(\.count).reduce(0, +)
                p.callers = p.callers.mapValues { $0.filter { $0.impact == .direct } }
                return p.callers.values.map(\.count).reduce(0, +) < before }),
            ("existing-test pattern", { p in defer { p.testPatterns = [] }; return !p.testPatterns.isEmpty }),
            ("generic/technology skill sections", { p in
                let before = p.skills.count
                p.skills.removeAll { $0.scope >= .technology }
                return p.skills.count < before }),
            ("source slices beyond the first three", { p in
                guard p.snippets.count > 3 else { return false }
                p.snippets = Array(p.snippets.prefix(3)); return true }),
            ("tests beyond two per symbol", { p in
                let before = p.tests.values.map(\.count).reduce(0, +)
                p.tests = p.tests.mapValues { Array($0.prefix(2)) }
                return p.tests.values.map(\.count).reduce(0, +) < before }),
            ("caller signatures", { p in
                var changed = false
                p.callers = p.callers.mapValues { $0.map { c in var c = c; if c.signature != nil { changed = true }; c.signature = nil; return c } }
                return changed }),
            ("all source slices", { p in defer { p.snippets = [] }; return !p.snippets.isEmpty }),
            ("module skill sections", { p in
                let before = p.skills.count
                p.skills.removeAll { $0.scope >= .module }
                return p.skills.count < before }),
        ]
        for (label, step) in steps {
            if step(&pack) { pack.omissions.append("\(label) (budget \(budget.maxTokens) tokens)") }
            if !over() { return }
        }
    }

    // MARK: Facts and slices

    /// One-line AST summary: only non-zero facts.
    static func facts(_ d: Declaration) -> String? {
        var parts: [String] = []
        if d.isAsync { parts.append("async") }
        if d.isThrows { parts.append("throws" + (d.typedThrows.map { "(\($0))" } ?? "")) }
        if !d.isolationMarkers.isEmpty { parts.append("isolation=\(d.isolationMarkers.joined(separator: ","))") }
        if let b = d.body {
            let counts = [("if", b.ifCount), ("guard", b.guardCount), ("switch", b.switchCount), ("case", b.caseCount), ("loop", b.loopCount),
                          ("throw", b.throwCount), ("try", b.tryCount), ("catch", b.catchCount), ("await", b.awaitCount)]
            parts += counts.filter { $0.1 > 0 }.map { "\($0.0)=\($0.1)" }
            if !b.thrownTypes.isEmpty { parts.append("throwsTypes=\(b.thrownTypes.joined(separator: ","))") }
            if !b.concurrencyConstructs.isEmpty { parts.append("concurrency=\(b.concurrencyConstructs.joined(separator: ","))") }
            if !b.assignedMembers.isEmpty { parts.append("assigns=\(b.assignedMembers.prefix(8).joined(separator: ","))") }
            if !b.matchedCases.isEmpty { parts.append("cases=\(b.matchedCases.prefix(12).joined(separator: ","))") }
            parts.append("lines=\(b.lineCount)")
        }
        if !d.genericConstraints.isEmpty { parts.append("where=\(d.genericConstraints.joined(separator: ","))") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Changed lines inside the declaration (±3 lines of context) or its head, bounded and redacted.
    static func slice(_ text: String, _ span: SourceSpan, changed: [ClosedRange<Int>]?, maxLines: Int) -> (lines: String, text: String)? {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard span.line >= 1, span.line <= all.count else { return nil }
        let declLines = span.line...min(span.endLine, all.count)
        var wanted = Set<Int>()
        let relevant = (changed ?? []).compactMap { r -> ClosedRange<Int>? in r.overlaps(declLines) ? max(r.lowerBound, declLines.lowerBound)...min(r.upperBound, declLines.upperBound) : nil }
        if relevant.isEmpty {
            wanted = Set(declLines.prefix(maxLines))
        } else {
            wanted.insert(span.line)
            for r in relevant { for l in (r.lowerBound - 3)...(r.upperBound + 3) where declLines.contains(l) { wanted.insert(l) } }
        }
        let chosen = wanted.sorted().prefix(maxLines)
        var out: [String] = []
        var previous: Int?
        for l in chosen {
            if let p = previous, l > p + 1 { out.append("    …") }
            out.append(String(all[l - 1]))
            previous = l
        }
        if let last = chosen.last, last < declLines.upperBound { out.append("    … (\(declLines.upperBound - last) more lines)") }
        return ("\(chosen.first ?? span.line)-\(chosen.last ?? span.line)", SnippetRedactor.redact(out.joined(separator: "\n")))
    }
}

/// Removes credential-looking literals from source text before it can reach a model.
enum SnippetRedactor {
    static let patterns = [
        #"AIza[0-9A-Za-z_\-]{35}"#,                       // Google API keys
        #"sk-[A-Za-z0-9_\-]{20,}"#,                        // OpenAI/Anthropic-style secret keys
        #"gh[pousr]_[A-Za-z0-9]{36,}"#,                    // GitHub tokens
        #"(?i)bearer\s+[A-Za-z0-9._\-]{20,}"#,             // bearer tokens
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
    ]
    static func redact(_ text: String) -> String {
        patterns.reduce(text) { t, p in t.replacingOccurrences(of: p, with: "<REDACTED>", options: .regularExpression) }
    }
}
