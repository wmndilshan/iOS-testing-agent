import Foundation

public struct SpecIssue: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var specID: String
    public var severity: Severity
    public var message: String
    public var description: String { "\(specID) [\(severity.rawValue)] \(message)" }
}

public struct RefinementRejection: Error, Sendable {
    public var issues: [SpecIssue]
}

/// Validates specifications, and gates LLM refinements of deterministic drafts. LLM output is untrusted: it may fill in
/// inputs, steps and expectations, but it may not retarget a spec, lower its risk, or remove a live/approval gate.
public enum TestSpecificationValidator {
    static let idPattern = #"^[A-Z0-9]{1,6}-[A-Z0-9]{3}-[0-9]{3}$"#
    static let operationPattern = #"^[a-z][A-Za-z0-9]{1,63}$"#
    static let maxTextLength = 500
    static let maxItems = 30

    public static func validate(_ s: TestSpecification, index: ASTIndex) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        func error(_ m: String) { issues.append(SpecIssue(specID: s.id, severity: .error, message: m)) }
        func warning(_ m: String) { issues.append(SpecIssue(specID: s.id, severity: .warning, message: m)) }

        if s.id.range(of: idPattern, options: .regularExpression) == nil { error("id does not match PREFIX-CAT-NNN") }
        if index[s.targetSymbol] == nil { error("target symbol \(s.targetSymbol) is not in the index") }
        if s.steps.isEmpty { error("no steps") }
        if s.expectedOutcome.isEmpty { error("no expected outcome") }
        if s.liveRequired, !s.approvalRequired { error("a live-required spec must require human approval") }
        if s.category.needsSpecialInfrastructure, !s.liveRequired, s.category == .endToEnd { error("end-to-end specs must be live-required") }

        let texts = [s.title, s.purpose, s.failureExpectation ?? ""] + s.preconditions + s.fixtures + s.steps.map(\.text) + s.expectedOutcome.map(\.text)
            + s.cleanup.map(\.text) + s.inputs.map(\.value) + s.openQuestions
        if texts.contains(where: { $0.count > maxTextLength }) { error("a field exceeds \(maxTextLength) characters") }
        if texts.contains(where: { $0.contains("```") || $0.contains("import XCTest") || $0.contains("import Testing") || $0.contains("@Test") }) {
            error("fields must describe behavior, not contain source code")
        }
        let lists = [s.preconditions.count, s.fixtures.count, s.inputs.count, s.steps.count, s.expectedOutcome.count, s.cleanup.count]
        if lists.contains(where: { $0 > maxItems }) { error("a list exceeds \(maxItems) items") }

        for op in (s.steps + s.cleanup).compactMap(\.operation) {
            if op.name.range(of: operationPattern, options: .regularExpression) == nil { error("operation name '\(op.name)' is not an identifier") }
            if let subject = op.subject, index[subject] == nil { error("operation \(op.name) targets unknown symbol \(subject)") }
        }
        let unmapped = s.steps.filter { $0.operation == nil }.count + s.expectedOutcome.filter { $0.assertion == nil }.count
        if unmapped > 0 { warning("\(unmapped) step(s)/expectation(s) have no machine operation; the instruction cannot be compiled until they do") }
        if !s.unresolvedPlaceholders.isEmpty { warning("unresolved: " + s.unresolvedPlaceholders.joined(separator: ", ")) }
        return issues
    }

    /// Accepts an LLM refinement of `draft` only if the invariant fields are preserved (or made stricter).
    public static func acceptRefinement(_ refined: TestSpecification, of draft: TestSpecification, index: ASTIndex) -> Result<TestSpecification, RefinementRejection> {
        var issues = validate(refined, index: index).filter { $0.severity == .error }
        func reject(_ m: String) { issues.append(SpecIssue(specID: draft.id, severity: .error, message: m)) }
        if refined.id != draft.id { reject("id changed") }
        if refined.targetSymbol != draft.targetSymbol { reject("target symbol changed") }
        if refined.behaviorID != draft.behaviorID { reject("behavior changed") }
        if refined.risk < draft.risk { reject("risk lowered from \(draft.risk.rawValue) to \(refined.risk.rawValue)") }
        if draft.liveRequired, !refined.liveRequired { reject("live requirement removed") }
        if draft.approvalRequired, !refined.approvalRequired { reject("approval requirement removed") }
        if refined.status == .approved { reject("only a human can approve a spec") }
        guard issues.isEmpty else { return .failure(RefinementRejection(issues: issues)) }
        var accepted = refined
        accepted.provenance = .llm
        accepted.status = .refined
        accepted.sourceReferences = draft.sourceReferences   // provenance comes from the index, not the model
        return .success(accepted)
    }
}
