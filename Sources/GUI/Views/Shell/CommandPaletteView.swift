import SwiftUI
import AgentCore
import AgentPresentation

/// Cmd+K: jump to a section, run a case or open a past run from one search field. Arrow keys move, Return chooses, Escape closes.
struct CommandPaletteView: View {
    @EnvironmentObject private var workspace: WorkspaceState
    @EnvironmentObject private var caseRun: CaseRunState
    @EnvironmentObject private var history: RunHistoryState
    @EnvironmentObject private var tests: TestLibraryState
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool

    private var items: [PaletteItem] {
        CommandPalette.items(query: query,
                             caseKeys: tests.records.map { (key: $0.key, title: $0.title) },
                             runs: history.entries.map { (id: $0.id, key: $0.key, outcome: $0.outcome) },
                             isRunning: caseRun.isRunning)
    }

    var body: some View {
        let shown = items
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a section, run a case, open a run", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { choose(shown.first { $0.id == selection } ?? shown.first) }
                    .accessibilityLabel("Command palette search")
            }
            .padding(DS.Space.m)
            Divider()
            if shown.isEmpty {
                Text("Nothing matches “\(query)”.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    List(shown, selection: $selection) { item in
                        HStack(spacing: DS.Space.m) {
                            Image(systemName: item.symbol).frame(width: 20).foregroundStyle(.secondary)
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { choose(item) }
                        .tag(item.id)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.plain)
                    .onChange(of: selection) { id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        // Arrow keys as invisible buttons: `onKeyPress` needs macOS 14.
        .background {
            Group {
                Button("") { move(1, in: shown) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { move(-1, in: shown) }.keyboardShortcut(.upArrow, modifiers: [])
            }
            .opacity(0).accessibilityHidden(true)
        }
        .frame(width: 560, height: 380)
        .onAppear { focused = true; selection = items.first?.id }
        .onChange(of: query) { _ in selection = items.first?.id }
        .onExitCommand { workspace.isPaletteOpen = false }
    }

    private func move(_ delta: Int, in shown: [PaletteItem]) {
        guard !shown.isEmpty else { return }
        let current = shown.firstIndex { $0.id == selection } ?? 0
        selection = shown[min(max(current + delta, 0), shown.count - 1)].id
    }

    private func choose(_ item: PaletteItem?) {
        guard let item else { return }
        workspace.isPaletteOpen = false
        switch item.action {
        case .show(let section): workspace.show(section)
        case .runCase(let key): workspace.show(.run); caseRun.start(key: key)
        case .openRun(let id): workspace.show(.history); history.selectedID = id
        case .stopRun: caseRun.stop()
        }
    }
}
