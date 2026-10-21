import Foundation
import AgentCore
import TestCaseSources

/// Drafts test cases from a written requirement: Gherkin scenarios, or a story whose acceptance criteria are a list. It reshapes the text
/// without a model (see `StoryDrafter`), so a preview is free and repeatable; `write=true` saves the drafts in TestCases/ for the agent to refine.
enum GenerateCasesTool {
    /// The most a requirement file may be: a story, not a book.
    static let maxCharacters = 60_000

    static func tool(_ services: GatewayServices, _ store: FileTestCaseStore) -> GatewayTool {
        GatewayTool(name: "generate_cases", description: "Draft test cases from a requirement: Gherkin (Feature/Scenario/Given/When/Then) or a story with acceptance criteria as a list. Give the text, or a file inside the project. Without write=true it only previews. Saved drafts get keys PREFIX-1, PREFIX-2… and source agent; refine them with read_case and write_case replace=true before running. For a code change use plan_tests instead.",
                    properties: ["text": Schema.string("The requirement text"), "file": Schema.string("A markdown or text file inside the project, instead of text"),
                                 "key_prefix": Schema.string("Prefix for the new keys, default GEN"), "write": Schema.boolean("Save the drafts in TestCases/ (default: preview only)")],
                    readOnly: false) { args, _ in
            var source = args.string("text") ?? ""
            if let file = args.string("file") {
                guard let text = readInsideProject(file, services.projectRoot) else { return .error("file must be a readable text file inside the project.") }
                source = text
            }
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error("Give text or file.") }
            let drafts = StoryDrafter.drafts(from: String(source.prefix(maxCharacters)))
            guard !drafts.isEmpty else {
                return .error("No scenarios or acceptance criteria found. Use Gherkin (Scenario:, Given/When/Then) or a list of criteria (- or 1.).")
            }
            let cleanPrefix = (args.string("key_prefix") ?? "GEN").uppercased()
            guard FileTestCaseStore.normalizedKey(cleanPrefix + "-1") != nil else { return .error("key_prefix must be letters, digits, - or _.") }
            let write = args.bool("write") == true
            var taken = Set(store.keys())
            var lines: [String] = []
            for draft in drafts {
                var number = 1
                while taken.contains("\(cleanPrefix)-\(number)") { number += 1 }
                let key = "\(cleanPrefix)-\(number)"
                taken.insert(key)
                var line = "\(key) — \(draft.title) (\(draft.steps.count) steps)"
                if write {
                    do { try store.save(key: key, title: draft.title, source: "agent", steps: draft.steps); line += " saved" }
                    catch { line += " NOT saved: \(error.localizedDescription)" }
                }
                lines.append(line)
                lines += draft.steps.map { "  \($0.number). \($0.action) → expect: \($0.expected)" }
                lines += draft.notes.map { "  note: \($0)" }
            }
            lines.append(write ? "Refine the drafts, then run one with run_case." : "Preview only. Call again with write=true to save these.")
            return .text(lines.joined(separator: "\n"))
        }
    }

    /// The file's text when it lies inside the project root (symlinks resolved), else nil.
    static func readInsideProject(_ path: String, _ root: URL) -> String? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"), let data = try? Data(contentsOf: url), data.count <= maxCharacters * 4 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
