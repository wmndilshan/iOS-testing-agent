import Foundation

/// Precedence of a skill; earlier cases win. Project rules beat module rules beat technology rules beat generic advice.
public enum SkillScope: String, Codable, Sendable, CaseIterable, Comparable {
    case project, module, technology, generic
    public static func < (a: SkillScope, b: SkillScope) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

public struct SkillApplicability: Codable, Hashable, Sendable {
    /// Globs over repository paths (`**` any depth, `*` within a component).
    public var paths: [String] = []
    public var modules: [String] = []
    /// Simple type or member names (`WorkflowScheduler`, `dispatchCurrentStep`).
    public var symbols: [String] = []
    public var technologies: [String] = []
    public var categories: [String] = []
    public var traits: [String] = []
    public var isEmpty: Bool { paths.isEmpty && modules.isEmpty && symbols.isEmpty && technologies.isEmpty && categories.isEmpty && traits.isEmpty }
}

/// A `## ` section of a skill. `<!-- when: categories=a,b; traits=c; technologies=d -->` right after the heading limits it
/// to matching contexts; a section without the marker applies whenever its skill does.
public struct SkillSection: Codable, Hashable, Sendable {
    public var heading: String
    public var body: String
    public var when: SkillApplicability?
}

public struct TestingSkill: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var path: String
    public var scope: SkillScope
    public var appliesTo: SkillApplicability
    /// Machine-checkable instructions (`framework: swift-testing`). Two applicable skills that set the same key to
    /// different values conflict; see `SkillResolver`.
    public var directives: [String: String]
    public var sections: [SkillSection]
}

public enum SkillParseError: Error, Equatable, CustomStringConvertible {
    case missingFrontmatter(String)
    case missingField(String, field: String)
    case invalidScope(String, value: String)

    public var description: String {
        switch self {
        case .missingFrontmatter(let p): "\(p): no `---` frontmatter"
        case .missingField(let p, let f): "\(p): missing `\(f)`"
        case .invalidScope(let p, let v): "\(p): scope `\(v)` is not one of project, module, technology, generic"
        }
    }
}

/// Parses SKILL.md: YAML-subset frontmatter (scalars, `[a, b]` lists, `- item` lists, one nesting level) and `## ` sections.
public enum SkillParser {

    public static func parse(_ text: String, path: String) throws -> TestingSkill {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw SkillParseError.missingFrontmatter(path)
        }
        let meta = frontmatter(Array(lines[1..<end]))
        guard let name = meta.scalars["name"], !name.isEmpty else { throw SkillParseError.missingField(path, field: "name") }
        let scopeText = meta.scalars["scope"] ?? "generic"
        guard let scope = SkillScope(rawValue: scopeText) else { throw SkillParseError.invalidScope(path, value: scopeText) }
        let a = meta.maps["applies-to"] ?? [:]
        let applicability = SkillApplicability(paths: a["paths"] ?? [], modules: a["modules"] ?? [], symbols: a["symbols"] ?? [],
                                               technologies: a["technologies"] ?? [], categories: a["categories"] ?? [], traits: a["traits"] ?? [])
        let directives = (meta.maps["directives"] ?? [:]).mapValues { $0.joined(separator: ", ") }
        return TestingSkill(name: name, description: meta.scalars["description"] ?? "", path: path, scope: scope, appliesTo: applicability,
                            directives: directives, sections: sections(Array(lines[(end + 1)...])))
    }

    struct Frontmatter {
        var scalars: [String: String] = [:]
        var maps: [String: [String: [String]]] = [:]
    }

    static func frontmatter(_ lines: [String]) -> Frontmatter {
        var out = Frontmatter()
        var currentKey: String?
        var currentSub: String?
        for raw in lines where !raw.trimmingCharacters(in: .whitespaces).isEmpty && !raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                let item = unquote(String(line.dropFirst(2)))
                if let k = currentKey, let s = currentSub { out.maps[k, default: [:]][s, default: []].append(item) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                currentKey = key
                currentSub = nil
                if !value.isEmpty { out.scalars[key] = unquote(value) }
            } else if let k = currentKey {
                currentSub = key
                out.maps[k, default: [:]][key] = value.isEmpty ? [] : list(value)
            }
        }
        return out
    }

    static func list(_ value: String) -> [String] {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [unquote(value)] }
        return value.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) { return String(s.dropFirst().dropLast()) }
        return s
    }

    static func sections(_ lines: [String]) -> [SkillSection] {
        var out: [SkillSection] = []
        var heading: String?
        var body: [String] = []
        func flush() {
            guard let h = heading else { return }
            var when: SkillApplicability?
            var content = body
            if let first = content.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), let parsed = marker(first) {
                when = parsed
                content.removeAll { $0 == first }
            }
            out.append(SkillSection(heading: h, body: content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), when: when))
        }
        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                body = []
            } else if heading != nil {
                body.append(line)
            }
        }
        flush()
        return out
    }

    /// `<!-- when: categories=concurrency,persistence; traits=async -->`
    static func marker(_ line: String) -> SkillApplicability? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("<!--"), t.hasSuffix("-->"), let r = t.range(of: "when:") else { return nil }
        let spec = t[r.upperBound...].dropLast(3)
        var a = SkillApplicability()
        for clause in spec.split(separator: ";") {
            let kv = clause.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let values = kv[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            switch kv[0] {
            case "categories": a.categories = values
            case "traits": a.traits = values
            case "technologies": a.technologies = values
            case "paths": a.paths = values
            case "modules": a.modules = values
            case "symbols": a.symbols = values
            default: break
            }
        }
        return a
    }
}
