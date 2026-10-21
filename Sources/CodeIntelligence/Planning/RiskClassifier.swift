import Foundation

/// Engineering risk of a change: how much could break and how badly. Not a quality score and not a test score.
public enum RiskLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case low = "LOW", medium = "MEDIUM", high = "HIGH", critical = "CRITICAL"
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

public enum RiskFactor: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable, Comparable {
    case publicAPIChange, persistence, security, authorization, externalSideEffects, concurrency, stateMachine, recovery
    case workflowOrchestration, deviceInteraction, parsing, dataMigration, failureHandling, wideImpact, untested, interfaceRemoved

    public static func < (a: RiskFactor, b: RiskFactor) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    var weight: Int {
        switch self {
        case .authorization, .dataMigration: 4
        case .security, .persistence, .concurrency, .recovery, .interfaceRemoved: 3
        case .workflowOrchestration, .stateMachine, .deviceInteraction, .externalSideEffects, .publicAPIChange: 2
        case .parsing, .failureHandling, .wideImpact, .untested: 1
        }
    }
}

public struct RiskAssessment: Codable, Sendable {
    public var level: RiskLevel
    public var score: Int
    public var factors: [RiskFactor: String]
    /// A rule that raised the level above what the score alone gives.
    public var floorRule: String?
}

public enum RiskClassifier {
    /// Direct referrers above this count make a change "wide".
    public static let wideImpactThreshold = 10

    public static func assess(traits: [TraitEvidence], change: SymbolChange, directReferrers: Int, hasTests: Bool) -> RiskAssessment {
        var f: [RiskFactor: String] = [:]
        let t = Dictionary(traits.map { ($0.trait, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let map: [(BehaviorTrait, RiskFactor)] = [
            (.persistence, .persistence), (.security, .security), (.authorization, .authorization), (.externalSideEffects, .externalSideEffects),
            (.concurrency, .concurrency), (.stateMachine, .stateMachine), (.recovery, .recovery), (.workflowOrchestration, .workflowOrchestration),
            (.deviceInteraction, .deviceInteraction), (.parsing, .parsing), (.dataMigration, .dataMigration), (.failureHandling, .failureHandling),
        ]
        for (trait, factor) in map { if let r = t[trait] { f[factor] = r } }
        if change.isPublicAPI, change.isSignatureChange || change.kind == .removed { f[.publicAPIChange] = "public signature changed" }
        if change.kind == .removed, change.isInterface { f[.interfaceRemoved] = "cross-file declaration removed" }
        if directReferrers > wideImpactThreshold { f[.wideImpact] = "\(directReferrers) direct referrers" }
        if !hasTests, change.role == .production { f[.untested] = "no existing test references this symbol" }

        let score = f.keys.map(\.weight).reduce(0, +)
        var level: RiskLevel = score <= 2 ? .low : score <= 5 ? .medium : score <= 8 ? .high : .critical
        var floor: String?
        func raise(to l: RiskLevel, _ rule: String) { if level < l { level = l; floor = rule } }
        let logicChanged = !Set(change.aspects).isDisjoint(with: [.controlFlow, .signature, .errorHandling, .declarationRemoved])
        if f[.authorization] != nil {
            if logicChanged { raise(to: .critical, "authorization logic or signature changed") } else { raise(to: .high, "authorization code changed") }
        }
        if f[.dataMigration] != nil { raise(to: .high, "data migration changed") }
        if f[.persistence] != nil, f[.concurrency] != nil { raise(to: .high, "persistence under concurrency") }
        if f[.security] != nil, logicChanged { raise(to: .high, "security logic changed") }
        if f[.recovery] != nil, f[.externalSideEffects] != nil { raise(to: .high, "recovery of external side effects") }
        return RiskAssessment(level: level, score: score, factors: f, floorRule: floor)
    }

    /// Change-level risk is the highest symbol risk; test- and documentation-only changes are LOW by definition.
    /// `assessments` must be in a stable order (the pipeline sorts by symbol); ties keep the first.
    public static func overall(_ assessments: [RiskAssessment], changes: ChangeSet) -> RiskAssessment {
        if changes.isDocumentationOnly || changes.isTestOnly || assessments.isEmpty {
            return RiskAssessment(level: .low, score: 0, factors: [:], floorRule: changes.isDocumentationOnly ? "documentation only" : (changes.isTestOnly ? "tests only" : nil))
        }
        var merged: [RiskFactor: String] = [:]
        for a in assessments { merged.merge(a.factors) { old, _ in old } }
        let top = assessments.reduce(assessments[0]) { best, a in (a.level, a.score) > (best.level, best.score) ? a : best }
        return RiskAssessment(level: top.level, score: top.score, factors: merged, floorRule: top.floorRule)
    }
}
