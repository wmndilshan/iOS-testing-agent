import Foundation

/// What a change touches, as far as skill selection is concerned.
public struct SkillContext: Codable, Sendable {
    public var paths: [String]
    public var modules: Set<String>
    public var symbolNames: Set<String>
    public var technologies: Set<String>
    public var categories: Set<TestCategory>
    public var traits: Set<BehaviorTrait>

    public init(paths: [String], modules: Set<String>, symbolNames: Set<String>, technologies: Set<String>, categories: Set<TestCategory>, traits: Set<BehaviorTrait>) {
        self.paths = paths; self.modules = modules; self.symbolNames = symbolNames
        self.technologies = technologies; self.categories = categories; self.traits = traits
    }
}

public struct AppliedSkill: Codable, Sendable {
    public var name: String
    public var path: String
    public var scope: SkillScope
    public var matchedBy: [String]
    /// Only the sections relevant to the context.
    public var sections: [SkillSection]
    public var omittedSections: [String]
    public var directives: [String: String]
}

public struct SkillConflict: Codable, Hashable, Sendable {
    public enum Resolution: Codable, Hashable, Sendable {
        /// A higher-precedence skill set the value; lower ones were overridden (recorded, not silently merged).
        case precedence(winner: String)
        /// Skills of the same precedence disagree. A human must resolve it before tests are generated.
        case unresolved
    }
    public var directive: String
    public var values: [String: String]   // skill name -> value
    public var resolution: Resolution
}

public struct SkillResolution: Codable, Sendable {
    public var applied: [AppliedSkill]
    /// Skills found but not applicable, with the reason.
    public var omitted: [String: String]
    public var conflicts: [SkillConflict]
    /// Directives after precedence; keys with unresolved conflicts are absent.
    public var effectiveDirectives: [String: String]
    public var parseErrors: [String]
    public var requiresResolution: Bool { conflicts.contains { $0.resolution == .unresolved } }
}

public enum SkillResolver {

    /// Loads every SKILL.md under `root` (excluded directories are never read). Invalid skills are reported, not dropped silently.
    public static func discover(root: URL) -> (skills: [TestingSkill], errors: [String]) {
        let scanner = RepositoryScanner(root: root)
        var skills: [TestingSkill] = []
        var errors: [String] = []
        for path in scanner.files(named: "SKILL.md") {
            do {
                let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                skills.append(try SkillParser.parse(text, path: path))
            } catch {
                errors.append("\(error)")
            }
        }
        return (skills.sorted { ($0.scope, $0.name) < ($1.scope, $1.name) }, errors)
    }

    public static func resolve(_ skills: [TestingSkill], context: SkillContext, parseErrors: [String] = []) -> SkillResolution {
        var applied: [AppliedSkill] = []
        var omitted: [String: String] = [:]
        for skill in skills.sorted(by: { ($0.scope, $0.name) < ($1.scope, $1.name) }) {
            let reasons = matches(skill.appliesTo, context)
            let appliesByDefault = skill.appliesTo.isEmpty && skill.scope == .project
            guard !reasons.isEmpty || appliesByDefault else {
                omitted[skill.name] = "no path, module, symbol, technology, category or trait match"
                continue
            }
            var sections: [SkillSection] = []
            var omittedSections: [String] = []
            for s in skill.sections {
                if let when = s.when, matches(when, context).isEmpty { omittedSections.append(s.heading) } else { sections.append(s) }
            }
            applied.append(AppliedSkill(name: skill.name, path: skill.path, scope: skill.scope, matchedBy: appliesByDefault ? ["project-wide"] : reasons,
                                        sections: sections, omittedSections: omittedSections, directives: skill.directives))
        }
        let (conflicts, effective) = directives(applied)
        return SkillResolution(applied: applied, omitted: omitted, conflicts: conflicts, effectiveDirectives: effective, parseErrors: parseErrors)
    }

    /// Precedence: scope order (project > module > technology > generic). Disagreement at the winning scope is a conflict.
    static func directives(_ applied: [AppliedSkill]) -> ([SkillConflict], [String: String]) {
        var byKey: [String: [(AppliedSkill, String)]] = [:]
        for skill in applied { for (k, v) in skill.directives { byKey[k, default: []].append((skill, v)) } }
        var conflicts: [SkillConflict] = []
        var effective: [String: String] = [:]
        for (key, entries) in byKey.sorted(by: { $0.key < $1.key }) {
            let values = Dictionary(entries.map { ($0.0.name, $0.1) }, uniquingKeysWith: { a, _ in a })
            guard Set(entries.map(\.1)).count > 1 else { effective[key] = entries[0].1; continue }
            let topScope = entries.map(\.0.scope).min()!
            let top = entries.filter { $0.0.scope == topScope }
            if Set(top.map(\.1)).count == 1 {
                effective[key] = top[0].1
                conflicts.append(SkillConflict(directive: key, values: values, resolution: .precedence(winner: top.map(\.0.name).sorted().joined(separator: ","))))
            } else {
                conflicts.append(SkillConflict(directive: key, values: values, resolution: .unresolved))
            }
        }
        return (conflicts, effective)
    }

    static func matches(_ a: SkillApplicability, _ c: SkillContext) -> [String] {
        var out: [String] = []
        if let p = a.paths.first(where: { glob in c.paths.contains { Glob.matches(glob, $0) } }) { out.append("path \(p)") }
        if let m = a.modules.first(where: c.modules.contains) { out.append("module \(m)") }
        if let s = a.symbols.first(where: c.symbolNames.contains) { out.append("symbol \(s)") }
        if let t = a.technologies.first(where: c.technologies.contains) { out.append("technology \(t)") }
        if let k = a.categories.first(where: { TestCategory(rawValue: $0).map(c.categories.contains) ?? false }) { out.append("category \(k)") }
        if let t = a.traits.first(where: { BehaviorTrait(rawValue: $0).map(c.traits.contains) ?? false }) { out.append("trait \(t)") }
        return out
    }

    /// Technologies from imports and traits; the vocabulary used by `applies-to.technologies`.
    public static func technologies(imports: Set<String>, traits: Set<BehaviorTrait>) -> Set<String> {
        var t: Set<String> = ["swift"]
        let byImport = ["SwiftUI": "swiftui", "SwiftSyntax": "swiftsyntax", "SwiftParser": "swiftsyntax", "XCTest": "xctest", "Testing": "swift-testing",
                        "SQLite3": "sqlite", "Combine": "combine", "CryptoKit": "crypto", "Observation": "swiftui"]
        for i in imports { if let v = byImport[i] { t.insert(v) } }
        let byTrait: [BehaviorTrait: String] = [.concurrency: "swift-concurrency", .async: "swift-concurrency", .persistence: "persistence",
                                                .dataMigration: "persistence", .authorization: "security", .security: "security",
                                                .deviceInteraction: "ios-automation", .parsing: "parsing", .swiftUIView: "swiftui",
                                                .workflowOrchestration: "workflow"]
        for tr in traits { if let v = byTrait[tr] { t.insert(v) } }
        return t
    }
}

enum Glob {
    /// `**` matches any number of path components, `*` any characters within one component, `?` one character.
    static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex, pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    if i < pattern.endIndex, pattern[i] == "/" { i = pattern.index(after: i); regex += "(?:/)?" }
                    continue
                }
                regex += "[^/]*"
            } else if c == "?" { regex += "[^/]" } else { regex += NSRegularExpression.escapedPattern(for: String(c)) }
            i = pattern.index(after: i)
        }
        return path.range(of: regex + "$", options: .regularExpression) != nil
    }
}
