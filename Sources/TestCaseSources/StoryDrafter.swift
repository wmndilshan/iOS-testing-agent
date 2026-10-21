import Foundation

/// Turns a written requirement (Gherkin scenarios, or a story with acceptance criteria as a list) into draft test cases. No model is involved:
/// it only reshapes what the text already says, so the same text always gives the same drafts. A draft is a starting point; the calling agent
/// or a person refines the actions and expected results before the case is trusted.
public enum StoryDrafter {
    public struct Draft: Equatable, Sendable {
        public var title: String
        public var steps: [TestCaseStep]
        /// What a reader should check before trusting the draft: a step cut off, an expected result that was filled in.
        public var notes: [String]
    }

    /// The most steps a case holds (`FileTestCaseStore` refuses more).
    static let maxSteps = 25

    public static func drafts(from text: String) -> [Draft] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let gherkin = scenarios(in: lines)
        return gherkin.isEmpty ? criteria(in: lines) : gherkin
    }

    // MARK: Gherkin

    private static let keywords = ["given", "when", "then", "and", "but"]

    private static func keyword(_ line: String) -> (word: String, rest: String)? {
        let lower = line.lowercased()
        for word in keywords where lower.hasPrefix(word + " ") { return (word, String(line.dropFirst(word.count + 1)).trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func heading(_ line: String, _ names: [String]) -> String? {
        let lower = line.lowercased()
        for name in names where lower.hasPrefix(name + ":") { return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private static func scenarios(in lines: [String]) -> [Draft] {
        var result: [Draft] = []
        var feature = ""
        var title: String?
        var actions: [String] = []
        var expectations: [[String]] = []   // expectations[i] belong to actions[i]
        var seenThen = false

        func finish() {
            guard let name = title else { return }
            defer { title = nil; actions = []; expectations = []; seenThen = false }
            guard !actions.isEmpty else { return }
            var notes: [String] = []
            var steps: [TestCaseStep] = []
            for (index, action) in actions.enumerated() {
                var expected = expectations[index].joined(separator: "; ")
                if expected.isEmpty {
                    expected = "The screen shows the result of: \(action)"
                    notes.append("Step \(index + 1) had no Then; its expected result was filled in and should be made specific.")
                }
                steps.append(TestCaseStep(number: index + 1, action: action, expected: expected))
            }
            if steps.count > maxSteps {
                notes.append("The scenario had \(steps.count) steps; only the first \(maxSteps) are kept.")
                steps = Array(steps.prefix(maxSteps))
            }
            result.append(Draft(title: feature.isEmpty ? name : "\(feature): \(name)", steps: steps, notes: notes))
        }

        for line in lines {
            if let name = heading(line, ["feature"]) { finish(); feature = name; continue }
            if let name = heading(line, ["scenario outline", "scenario", "example"]) { finish(); title = name; continue }
            guard title != nil, let (word, rest) = keyword(line), !rest.isEmpty else { continue }
            switch word {
            case "then":
                seenThen = true
                attach(rest, to: &expectations, count: actions.count)
            case "and", "but":
                if seenThen { attach(rest, to: &expectations, count: actions.count) } else { actions.append(rest); expectations.append([]) }
            default:   // given, when
                if seenThen { seenThen = false }
                actions.append(rest); expectations.append([])
            }
        }
        finish()
        return result
    }

    /// A Then belongs to the step before it; with no step yet, it is dropped (a scenario cannot start with a result).
    private static func attach(_ text: String, to expectations: inout [[String]], count: Int) {
        guard count > 0 else { return }
        expectations[count - 1].append(text)
    }

    // MARK: Acceptance criteria

    private static func criteria(in lines: [String]) -> [Draft] {
        var title = ""
        var bullets: [String] = []
        for line in lines {
            if line.hasPrefix("#"), title.isEmpty { title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces); continue }
            if let bullet = bullet(line), !bullet.isEmpty { bullets.append(bullet) }
        }
        guard !bullets.isEmpty else { return [] }
        var notes = ["Each acceptance criterion became one step; the actions are placeholders to rewrite as taps and entries."]
        if bullets.count > maxSteps { notes.append("There were \(bullets.count) criteria; only the first \(maxSteps) are kept.") }
        let steps = bullets.prefix(maxSteps).enumerated().map { index, text in
            TestCaseStep(number: index + 1, action: "Do what is needed to check: \(text)", expected: text)
        }
        return [Draft(title: title.isEmpty ? "Acceptance criteria" : title, steps: steps, notes: notes)]
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where line.hasPrefix(marker) { return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces) }
        if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
        return nil
    }
}
