import Foundation

/// Provider-neutral prompt for refining draft specs. The caller sends `system` + `user` through whatever LLM port it
/// owns; this module never talks to a model or the network.
public struct TestGenerationRequest: Codable, Sendable {
    public var system: String
    public var user: String
    public var estimatedTokens: Int
    public var specIDs: [String]

    public static func make(_ plan: TestPlan) -> TestGenerationRequest {
        let drafts = plan.specifications.filter { plan.blocked[$0.id] != nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Source references are index facts; the model does not need them and must not rewrite them.
        let payload = drafts.map { s -> TestSpecification in var s = s; s.sourceReferences = []; return s }
        let json = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let system = """
        You refine draft test specifications for a Swift codebase. You do not write Swift code.
        Rules:
        - Fill every "<TBD>" and answer every openQuestion using only the context provided. If you cannot, say so in openQuestions and leave "<TBD>".
        - Keep id, targetSymbol, behaviorID, category, risk, liveRequired and approvalRequired unchanged. Never set status to "approved".
        - Every step needs an operation (lowerCamelCase identifier) and every expectation an assertion (subject, comparator, expected).
        - Follow the testing instructions from SKILL.md in the context; higher precedence wins. Do not resolve UNRESOLVED skill conflicts yourself.
        - If the context is insufficient to decide expected behavior, reply exactly {"escalate": "<what is missing>"} instead of guessing.
        Reply with a JSON array of the refined specifications only.
        """
        let user = plan.contextPack.render() + "\n\n## Draft specifications (JSON)\n" + json
        return TestGenerationRequest(system: system, user: user, estimatedTokens: ContextPack.estimateTokens(system + user), specIDs: drafts.map(\.id))
    }
}

public enum TestGenerationResponse: Sendable {
    case refinements(accepted: [TestSpecification], rejected: [SpecIssue])
    /// The model asked for more context; pass the reason to `ContextPackBuilder.escalate`.
    case escalate(String)
    case invalid(String)

    /// Parses and gates a model reply. Every refinement must match a draft and pass `acceptRefinement`.
    public static func parse(_ text: String, drafts: [TestSpecification], index: ASTIndex) -> TestGenerationResponse {
        let trimmed = stripFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let data = Data(trimmed.utf8)
        if let e = try? JSONDecoder().decode([String: String].self, from: data), let reason = e["escalate"] { return .escalate(reason) }
        let decoded: [TestSpecification]
        do { decoded = try JSONDecoder().decode([TestSpecification].self, from: data) } catch {
            return .invalid("reply is not a JSON array of TestSpecification: \(error)")
        }
        let byID = Dictionary(drafts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var accepted: [TestSpecification] = []
        var rejected: [SpecIssue] = []
        for r in decoded {
            guard let draft = byID[r.id] else {
                rejected.append(SpecIssue(specID: r.id, severity: .error, message: "no draft with this id"))
                continue
            }
            switch TestSpecificationValidator.acceptRefinement(r, of: draft, index: index) {
            case .success(let s): accepted.append(s)
            case .failure(let rejection): rejected += rejection.issues
            }
        }
        return .refinements(accepted: accepted, rejected: rejected)
    }

    private static func stripFence(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()
        if lines.last?.hasPrefix("```") ?? false { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
