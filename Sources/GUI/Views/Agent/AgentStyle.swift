import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

enum AgentStyle {
    static func color(_ agent: String) -> Color {
        switch agent {
        case "Orchestrator": return DS.accent
        case "RepoAnalyst", "CaseAuthor", "Runner", "Validator": return .secondary
        default: return .secondary
        }
    }

    static func symbol(_ agent: String) -> String {
        switch agent {
        case "Orchestrator": return "point.3.connected.trianglepath.dotted"
        case "RepoAnalyst": return "doc.text.magnifyingglass"
        case "CaseAuthor": return "square.and.pencil"
        case "Runner": return "play.fill"
        case "Validator": return "checkmark.seal.fill"
        default: return "person.fill"
        }
    }

    static func toolSymbol(_ tool: String) -> String {
        switch tool {
        case "repo_overview": return "map"
        case "ui_strings": return "textformat"
        case "file_outline", "describe_symbol", "code_index": return "list.bullet.indent"
        case "search_text": return "magnifyingglass"
        case "read_file", "read_case": return "doc.text"
        case "list_dir", "list_cases": return "folder"
        case "plan_tests": return "checklist"
        case "write_test_case": return "square.and.arrow.down"
        case "run_case": return "play.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    /// `{"path":"Sources/App.swift","from":1}` as `path: Sources/App.swift`, short enough for one line.
    static func argumentSummary(_ json: String) -> String {
        guard let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !object.isEmpty else { return "" }
        let parts = object.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
            guard let text = value as? String ?? (value as? NSNumber).map({ "\($0)" }) else { return nil }
            return "\(key): \(text.prefix(48))"
        }
        return parts.joined(separator: "  ")
    }
}

struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: AgentStyle.symbol(name)).font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(AgentStyle.color(name)).frame(width: size, height: size)
            .background(AgentStyle.color(name).opacity(0.16), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The team at a glance: who is working, who is done.
struct AgentStatusStrip: View {
    let agents: [AgentStatus]

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(agents) { agent in
                HStack(spacing: 5) {
                    switch agent.phase {
                    case .working: InlineSpinner()
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusTone.success.tint).imageScale(.small)
                    case .idle: Image(systemName: AgentStyle.symbol(agent.id)).foregroundStyle(.tertiary).imageScale(.small)
                    }
                    Text(agent.id).font(.caption.weight(agent.phase == .working ? .semibold : .regular))
                        .foregroundStyle(agent.phase == .idle ? .secondary : AgentStyle.color(agent.id))
                }
                .padding(.horizontal, DS.Space.s).padding(.vertical, 4)
                .background(agent.phase == .working ? AgentStyle.color(agent.id).opacity(0.14) : Color.primary.opacity(0.04), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(agent.id) \(agent.phase == .working ? "working" : agent.phase == .done ? "done" : "idle")")
            }
        }
    }
}
