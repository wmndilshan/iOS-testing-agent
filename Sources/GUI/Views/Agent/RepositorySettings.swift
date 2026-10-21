import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// Folder chooser for the repository the agents read.
enum RepositoryPicker {
    @MainActor
    static func choose(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use Repository"
        panel.message = "Choose the local repository the agents may read. They never change it."
        let expanded = (path as NSString).expandingTildeInPath
        if !expanded.isEmpty { panel.directoryURL = URL(fileURLWithPath: expanded) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// One line saying whether the chosen folder can be used.
struct RepositoryStatusLine: View {
    let status: RepositoryStatus

    var body: some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(tone.tint)
    }

    private var tone: StatusTone {
        switch status {
        case .ready(let swiftProject): return swiftProject ? .success : .warning
        case .notSet: return .neutral
        case .missing, .notAFolder: return .failure
        }
    }

    private var symbol: String {
        switch status {
        case .ready(let swiftProject): return swiftProject ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .notSet: return "folder.badge.questionmark"
        case .missing, .notAFolder: return "xmark.octagon.fill"
        }
    }

    private var text: String {
        switch status {
        case .ready(let swiftProject): return swiftProject ? "Ready: read-only" : "Folder found, but no Package.swift or Xcode project: code analysis covers Swift files only"
        case .notSet: return "No repository selected"
        case .missing: return "That folder does not exist"
        case .notAFolder: return "That path is a file, not a folder"
        }
    }
}

/// The Settings window (Cmd+,): which local repository the agents read, and which model provider they use.
/// The Settings window: the agents' settings, and a tab for what the app needs and how other tools connect to it.
struct SettingsRootView: View {
    let projectRoot: URL
    var body: some View {
        TabView {
            AgentSettingsView().tabItem { Label("Agents", systemImage: "bubble.left.and.bubble.right") }
            ConnectionsSettingsView(projectRoot: projectRoot).tabItem { Label("Connections", systemImage: "link") }
        }
        .frame(width: 560)
    }
}

/// Readiness of what a run needs, and the command that connects an AI tool (Claude Code, Codex, Cursor) to this project over MCP.
private struct ConnectionsSettingsView: View {
    let projectRoot: URL
    @Environment(\.idbAvailable) private var idbAvailable
    @Environment(\.hasModelKey) private var hasModelKey

    private var command: String { "claude mcp add autonomous-testing-agent -- ata-mcp --project-root=\(projectRoot.path)" }

    var body: some View {
        Form {
            Section {
                row("idb (reads the screen, sends taps)", ok: idbAvailable)
                row("Model key (GEMINI_API_KEY or DEEPSEEK_API_KEY in .env)", ok: hasModelKey)
            } header: { Text("Needed to run cases") }
            Section {
                Text("Other AI tools can use this app's simulator and test cases through the ata-mcp server. For Claude Code:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(command).font(DS.Typography.monoCaption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                CopyButton(text: command, label: "Copy command")
                Text("Codex, Cursor and others: see docs/INTEGRATIONS.md. Add --http=<port> to serve it over HTTP instead of stdio.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Connect an AI tool (MCP)") }
        }
        .formStyle(.grouped)
        .padding(.vertical, DS.Space.s)
    }

    private func row(_ title: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? DS.Palette.success : DS.Palette.warning)
            Text(title)
            Spacer()
            Text(ok ? "Ready" : "Missing").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AgentSettingsView: View {
    @EnvironmentObject var chat: AgentChatState
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Repository path", text: $draft, prompt: Text("/Users/you/Projects/MyApp"))
                        .textFieldStyle(.roundedBorder).onSubmit { chat.setRepositoryPath(draft) }
                        .accessibilityLabel("Repository path")
                    Button("Choose…") {
                        if let path = RepositoryPicker.choose(startingAt: draft) { draft = path; chat.setRepositoryPath(path) }
                    }
                    Button("Clear") { draft = ""; chat.setRepositoryPath("") }.disabled(draft.isEmpty)
                }
                RepositoryStatusLine(status: AgentChatState.status(ofRepositoryAt: draft))
                Text("The agents read this folder (files, search, code index) to write test cases. They cannot write to it. Secrets such as .env files and keys are never readable.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Repository") }

            Section {
                Picker("Model provider", selection: $chat.provider) {
                    Text("DeepSeek").tag("deepseek")
                    Text("Gemini").tag("gemini")
                }
                Text("Keys come from .env (DEEPSEEK_API_KEY, GEMINI_API_KEY). A change applies to the next conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Agents") }

            Section { FlowEditor() } header: { Text("Agent flow") }
        }
        .formStyle(.grouped)
        .padding(.vertical, DS.Space.s)
        .onAppear { draft = chat.repositoryPath }
        .onDisappear { chat.setRepositoryPath(draft) }
        .onChange(of: chat.repositoryPath) { draft = $0 }
    }
}
