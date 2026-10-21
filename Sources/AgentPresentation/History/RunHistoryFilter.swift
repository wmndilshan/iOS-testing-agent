import Foundation

/// Which past runs the History list shows.
public enum RunOutcomeFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case passed = "Passed"
    case failed = "Failed"
    case other = "Other"

    public var id: String { rawValue }

    /// "Other" is everything that neither passed nor failed: blocked, incomplete, stopped, or still marked running.
    public func includes(_ outcome: String) -> Bool {
        switch self {
        case .all: true
        case .passed: outcome == "PASSED"
        case .failed: outcome == "FAILED"
        case .other: outcome != "PASSED" && outcome != "FAILED"
        }
    }
}

extension RunHistoryState {
    /// The entries that pass the outcome filter and match the search text in their key, title or outcome.
    public func filtered(outcome: RunOutcomeFilter, query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            outcome.includes(entry.outcome)
                && (needle.isEmpty || [entry.key, entry.title, entry.outcome].contains { $0.localizedCaseInsensitiveContains(needle) })
        }
    }

    /// Share of finished runs (passed or failed) that passed, 0...1, or nil when none finished. Blocked and stopped runs say nothing about the app.
    public var passRate: Double? {
        let passed = entries.filter { $0.outcome == "PASSED" }.count
        let failed = entries.filter { $0.outcome == "FAILED" }.count
        return passed + failed == 0 ? nil : Double(passed) / Double(passed + failed)
    }
}
