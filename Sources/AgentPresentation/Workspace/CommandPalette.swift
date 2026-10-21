import Foundation

/// One line of the Cmd+K palette. The view decides what choosing it does; this only names it.
public struct PaletteItem: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case show(WorkspaceSection)
        case runCase(key: String)
        case openRun(id: String)
        case stopRun
    }

    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    public let action: Action

    public init(title: String, detail: String, symbol: String, action: Action) {
        self.id = "\(action)"
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.action = action
    }
}

/// Builds and ranks the palette's lines. Pure: the caller passes what exists right now.
public enum CommandPalette {
    /// Most lines shown for an empty query, and for a query: enough to scan, few enough that the best one is always on screen.
    static let limit = 40

    public static func items(query: String, caseKeys: [(key: String, title: String)], runs: [(id: String, key: String, outcome: String)],
                             isRunning: Bool) -> [PaletteItem] {
        var all: [PaletteItem] = WorkspaceSection.allCases.map {
            PaletteItem(title: "Go to \($0.title)", detail: "⌘\($0.shortcutDigit)", symbol: $0.symbolName, action: .show($0))
        }
        if isRunning { all.append(PaletteItem(title: "Stop the running case", detail: "Action", symbol: "stop.circle", action: .stopRun)) }
        all += caseKeys.map { PaletteItem(title: "Run \($0.key)", detail: $0.title, symbol: "play.circle", action: .runCase(key: $0.key)) }
        all += runs.prefix(30).map { PaletteItem(title: "Open run \($0.key)", detail: $0.outcome.capitalized, symbol: "clock.arrow.circlepath", action: .openRun(id: $0.id)) }

        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Array(all.prefix(limit)) }
        let words = needle.split(separator: " ").map(String.init)
        return all.compactMap { item -> (PaletteItem, Int)? in
            let title = item.title.lowercased(), detail = item.detail.lowercased()
            guard words.allSatisfy({ title.contains($0) || detail.contains($0) }) else { return nil }
            // A title that starts with the query, or has a word that does, beats one that only contains it.
            var score = 0
            if title.hasPrefix(needle) { score += 3 }
            if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { score += 2 }
            if title.contains(needle) { score += 1 }
            return (item, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit).map(\.0)
    }
}
