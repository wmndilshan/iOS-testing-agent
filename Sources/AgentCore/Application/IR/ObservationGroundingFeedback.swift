import Foundation

/// The only text sent back to the LLM describing a grounding failure. Built purely
/// from `GroundingResult` (IR-derived: role/identifier/label/status/reason strings) and `ObservedUIVocabulary`
/// (element-derived: id/role/label/state) — neither type has a field capable of carrying a credential,
/// authorization token, host path, simulator UDID, execution ID, or shell/xcodebuild string, so this
/// function cannot leak any of those by construction. The final `SecretRedactor.redact` pass is defense in
/// depth, not the only protection.
public enum ObservationGroundingFeedback {
    public static func build(from result: GroundingResult, vocabulary: ObservedUIVocabulary) -> String {
        var lines = ["UNRESOLVED TARGET(S):"]
        for issue in result.blockingIssues {
            lines.append("- step '\(issue.stepID)' (\(issue.kind)): proposed identifier='\(issue.proposedIdentifier ?? "(none)")' label='\(issue.proposedLabel ?? "(none)")' role='\(issue.proposedRole ?? "(any)")' -> \(issue.status.rawValue): \(issue.reason)")
        }
        lines.append("")
        lines.append("Observed identifiers you may use:")
        let ids = vocabulary.elements.compactMap(\.accessibilityIdentifier).sorted()
        if ids.isEmpty {
            lines.append("  (none — no element in the current observation carries an accessibility identifier)")
        } else {
            for id in ids { lines.append("  \(id)") }
        }
        return SecretRedactor.redact(lines.joined(separator: "\n"))
    }
}
