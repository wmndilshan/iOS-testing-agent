import Foundation

/// A named operation a test performs (`persistRunningJob`, `invoke`), optionally on a symbol, with named arguments.
/// Operation names are identifiers, never code.
public struct OperationRef: Codable, Hashable, Sendable {
    public var name: String
    public var subject: SymbolID?
    public var arguments: [String: String]
    public init(name: String, subject: SymbolID? = nil, arguments: [String: String] = [:]) {
        self.name = name; self.subject = subject; self.arguments = arguments
    }
}

public enum Comparator: String, Codable, Sendable, CaseIterable {
    case equals, notEquals, isTrue, isFalse, isNil, isNotNil, throwsError, doesNotThrow, contains, notContains
    case count, greaterThan, lessThan, unchanged
}

/// A checkable expectation: `subject comparator expected` (`node.state equals recoveryRequired`).
public struct AssertionRef: Codable, Hashable, Sendable {
    public var subject: String
    public var comparator: Comparator
    public var expected: String
    public init(subject: String, comparator: Comparator, expected: String = "") {
        self.subject = subject; self.comparator = comparator; self.expected = expected
    }
}

public struct SpecStep: Codable, Hashable, Sendable {
    public var text: String
    public var operation: OperationRef?
    public init(_ text: String, _ operation: OperationRef? = nil) { self.text = text; self.operation = operation }
}

public struct SpecExpectation: Codable, Hashable, Sendable {
    public var text: String
    public var assertion: AssertionRef?
    public init(_ text: String, _ assertion: AssertionRef? = nil) { self.text = text; self.assertion = assertion }
}

public struct SpecInput: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var note: String?
}

/// The canonical, human-readable test plan item. Reviewed before any Swift is generated.
public struct TestSpecification: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case draft, refined, approved }
    public enum Provenance: String, Codable, Sendable { case deterministic, llm, human }

    /// Placeholder for a value the deterministic planner cannot know (expected results, concrete inputs).
    public static let toBeDetermined = "<TBD>"

    public var id: String
    public var title: String
    public var purpose: String
    public var category: TestCategory
    public var risk: RiskLevel
    public var targetSymbol: SymbolID
    public var behaviorID: String
    public var preconditions: [String]
    public var fixtures: [String]
    public var inputs: [SpecInput]
    public var steps: [SpecStep]
    public var expectedOutcome: [SpecExpectation]
    public var failureExpectation: String?
    public var cleanup: [SpecStep]
    public var requiredTools: [String]
    public var requiredMocks: [String]
    public var requiredArtifacts: [String]
    public var evidenceRequirements: [String]
    /// A human must approve this spec (and any live run) before it is executed.
    public var approvalRequired: Bool
    /// Needs a live simulator/device: a manual CLI run, never `swift test`.
    public var liveRequired: Bool
    public var sourceReferences: [SourceSpan]
    /// Existing test to extend instead of creating a new one, if any.
    public var extendsTest: SymbolID?
    public var status: Status
    public var provenance: Provenance
    /// What the planner could not decide; the LLM or a human must answer these.
    public var openQuestions: [String]

    /// Placeholders still present in operations, inputs or assertions.
    public var unresolvedPlaceholders: [String] {
        var out: [String] = []
        for i in inputs where i.value.contains(Self.toBeDetermined) { out.append("input \(i.name)") }
        for s in steps + cleanup {
            for (k, v) in (s.operation?.arguments ?? [:]).sorted(by: { $0.key < $1.key }) where v.contains(Self.toBeDetermined) { out.append("\(s.operation!.name).\(k)") }
        }
        for e in expectedOutcome where e.assertion?.expected.contains(Self.toBeDetermined) ?? false { out.append("expected \(e.assertion!.subject)") }
        return out
    }
}

public enum TestSpecificationRenderer {
    /// The human-readable form reviewers read before execution.
    public static func render(_ s: TestSpecification) -> String {
        var out: [String] = []
        out.append("TEST \(s.id) — \(s.title)")
        out.append("Category: \(s.category.rawValue)   Risk: \(s.risk.rawValue)   Status: \(s.status.rawValue) (\(s.provenance.rawValue))")
        out.append("Target: \(s.targetSymbol)")
        if let e = s.extendsTest { out.append("Extends: \(e)") }
        out.append("")
        out.append("Purpose:\n\(s.purpose)")
        func list(_ title: String, _ items: [String], numbered: Bool = false) {
            guard !items.isEmpty else { return }
            out.append("")
            out.append("\(title):")
            for (i, item) in items.enumerated() { out.append(numbered ? "\(i + 1). \(item)" : "- \(item)") }
        }
        list("Preconditions", s.preconditions)
        list("Fixtures", s.fixtures)
        list("Inputs", s.inputs.map { "\($0.name) = \($0.value)" + ($0.note.map { " (\($0))" } ?? "") })
        list("Steps", s.steps.map(\.text), numbered: true)
        list("Expected", s.expectedOutcome.map(\.text))
        if let f = s.failureExpectation { out.append(""); out.append("Failure expectation:\n\(f)") }
        list("Cleanup", s.cleanup.map(\.text))
        list("Mocks", s.requiredMocks)
        list("Tools", s.requiredTools)
        list("Evidence", s.evidenceRequirements)
        if s.liveRequired || s.approvalRequired {
            out.append("")
            out.append("Gates: " + [s.liveRequired ? "LIVE RUN REQUIRED" : nil, s.approvalRequired ? "HUMAN APPROVAL REQUIRED" : nil].compactMap { $0 }.joined(separator: ", "))
        }
        list("Open questions", s.openQuestions)
        list("Sources", s.sourceReferences.map(\.description))
        return out.joined(separator: "\n")
    }
}
