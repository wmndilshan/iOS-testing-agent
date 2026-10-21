import Foundation
import AgentCore
import AgentInfrastructure

/// A check of the screen that needs no model: the labels an expected result puts in quotes ("shows 'Mine' and 'Not Mine'") are looked
/// up in the accessibility tree. It backs up the screenshot judge, which decides; it can say "confirmed in the tree", never "failed".
enum QuickChecks {
    struct Result: Equatable {
        let found: [String]
        let missing: [String]
    }

    /// An opening quote is not preceded by a letter or digit, and a closing one is not followed by one, so the apostrophe in "the user's list"
    /// does not start a label.
    private static let quoted = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])['"‘“]([^'"’”\n]{2,60})['"’”](?![A-Za-z0-9])"#)

    static func labels(in expected: String) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for match in quoted.matches(in: expected, range: NSRange(expected.startIndex..., in: expected)) {
            guard let range = Range(match.range(at: 1), in: expected) else { continue }
            let label = String(expected[range]).trimmingCharacters(in: .whitespaces)
            if label.count >= 2, seen.insert(label.lowercased()).inserted { labels.append(label) }
        }
        return labels
    }

    static func evaluate(expected: String, in observation: Observation) -> Result {
        let texts = observation.elements.filter { !$0.isSecure }.flatMap { [$0.label, $0.identifier, $0.value] }.compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        var found: [String] = [], missing: [String] = []
        for label in labels(in: expected) {
            let needle = label.lowercased()
            if texts.contains(where: { $0 == needle || $0.contains(needle) }) { found.append(label) } else { missing.append(label) }
        }
        return Result(found: found, missing: missing)
    }
}

extension StepRunner {
    /// After the judge agreed: confirm the quoted labels in the tree, instantly. Never fails the step, since the judge saw the screen.
    func runQuickChecks(_ text: StepText) async {
        let id = "\(step.number).qc"
        guard let observation = await session.observe() else {
            session.recordRow(id, number: step.number, intent: text.expected, action: "check", .skipped, "the screen could not be read; the judge decided")
            return
        }
        let result = QuickChecks.evaluate(expected: text.expected, in: observation)
        if result.found.isEmpty && result.missing.isEmpty {
            session.recordRow(id, number: step.number, intent: text.expected, action: "check", .skipped, "no quoted labels to look up; the judge decided")
        } else if result.missing.isEmpty {
            session.recordRow(id, number: step.number, intent: "Labels on screen: " + result.found.joined(separator: ", "), action: "check", .passed,
                              "Confirmed in the accessibility tree: " + result.found.map { "'\($0)'" }.joined(separator: ", "))
        } else {
            session.recordRow(id, number: step.number, intent: text.expected, action: "check", .skipped,
                              "not in the accessibility tree: " + result.missing.map { "'\($0)'" }.joined(separator: ", ") + "; the judge saw the screen and decided")
        }
    }
}
