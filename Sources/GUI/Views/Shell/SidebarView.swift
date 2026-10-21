import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

struct SidebarView: View {
    @EnvironmentObject var workspace: WorkspaceState
    @EnvironmentObject var simulator: SimulatorPaneModel
    @EnvironmentObject var caseRun: CaseRunState
    @EnvironmentObject var agentChat: AgentChatState
    @EnvironmentObject var operate: OperateState
    @Environment(\.idbAvailable) private var idbPresent
    @State private var renaming: ConversationSummary?
    @State private var newTitle = ""
    @State private var deleting: ConversationSummary?

    var body: some View {
        List {
            ForEach(WorkspaceSection.allCases) { section in
                let selected = workspace.section == section
                Button { workspace.show(section) } label: {
                    HStack {
                        Label(section.title, systemImage: section.symbolName)
                        Spacer()
                        if section == .run {
                            if caseRun.prompt != nil {
                                Image(systemName: "hand.raised.fill").foregroundStyle(StatusTone.warning.tint).imageScale(.small)
                                    .help("The run is waiting for you").accessibilityLabel("The run is waiting for you")
                            } else if caseRun.isRunning { ActivityDot(label: "A run is in progress") }
                        }
                        if section == .agent {
                            if agentChat.isWaitingForPerson {
                                Image(systemName: "hand.raised.fill").foregroundStyle(StatusTone.warning.tint).imageScale(.small)
                                    .help("Waiting for your approval").accessibilityLabel("Waiting for your approval")
                            } else if agentChat.isBusy { ActivityDot(label: "The agents are working") }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2).padding(.horizontal, DS.Space.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.s).fill(selected ? DS.accent.opacity(0.22) : .clear))
                .fontWeight(selected ? .semibold : .regular)
                .accessibilityLabel("\(section.title) section")
                .accessibilityIdentifier("section-\(section.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { VStack(spacing: 0) { sectionList; footer } }
        .sheet(item: $renaming) { summary in
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Rename chat").font(.headline)
                TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder).frame(width: 280).onSubmit { commitRename(summary) }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { commitRename(summary) }.keyboardShortcut(.defaultAction).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(DS.Space.l)
        }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { summary in
            Button("Delete", role: .destructive) { agentChat.delete(summary.id) }
            Button("Cancel", role: .cancel) {}
        } message: { summary in Text("“\(summary.title)” and what the agents remember from it are removed. Test cases it wrote stay in TestCases.") }
    }

    private func commitRename(_ summary: ConversationSummary) {
        agentChat.rename(summary.id, to: newTitle)
        renaming = nil
    }

    /// Chats belong to the Agent section and sessions to Operate; the other sections have no list.
    @ViewBuilder private var sectionList: some View {
        switch workspace.section.sidebarList {
        case .chats: chatList
        case .sessions: sessionList
        case .none: EmptyView()
        }
    }

    /// Earlier Operate tasks, newest first. Choosing one shows its plan, timeline and result.
    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack {
                Text("Operate sessions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { operate.newSession() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New task").accessibilityLabel("New operate task").disabled(operate.isRunning)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if operate.sessions.isEmpty { Text("Tasks you run appear here.").font(.caption).foregroundStyle(.tertiary).padding(DS.Space.s) }
                    ForEach(operate.sessions) { session in
                        let active = session.id == operate.activeSessionID
                        Button { operate.select(session.id) } label: {
                            HStack(spacing: DS.Space.s) {
                                Image(systemName: session.status == "done" ? "checkmark.circle" : session.status == "running" ? "circle.dotted" : "xmark.circle")
                                    .imageScale(.small).foregroundStyle(session.status == "done" ? StatusTone.success.tint : session.status == "running" ? Color.secondary : StatusTone.failure.tint)
                                Text(session.task).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3).padding(.horizontal, DS.Space.s)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.s).fill(active ? DS.accent.opacity(0.22) : .clear))
                        .fontWeight(active ? .semibold : .regular)
                        .accessibilityLabel("Operate session \(session.task)")
                        .contextMenu { Button("Delete", role: .destructive) { operate.deleteSession(session.id) } }
                    }
                }
                .padding(.horizontal, DS.Space.s)
            }
            .frame(maxHeight: 180)
            .padding(.bottom, DS.Space.s)
        }
    }

    /// The conversations, newest first, under the sections. Choosing one opens the Agent section on it.
    private var chatList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack {
                Text("Chats").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { workspace.show(.agent); agentChat.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New chat (⌘N)").accessibilityLabel("New chat")
                    .disabled(!agentChat.hasMessages)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(agentChat.conversationRows) { summary in
                        let active = summary.id == agentChat.activeConversationID
                        Button { workspace.show(.agent); agentChat.select(summary.id) } label: {
                            HStack(spacing: DS.Space.s) {
                                Image(systemName: "bubble.left").imageScale(.small).foregroundStyle(.secondary)
                                Text(summary.title).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3).padding(.horizontal, DS.Space.s)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.s).fill(active && workspace.section == .agent ? DS.accent.opacity(0.22) : .clear))
                        .fontWeight(active ? .semibold : .regular)
                        .accessibilityLabel("Chat \(summary.title)")
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .contextMenu {
                            Button("Rename…") { newTitle = summary.title; renaming = summary }
                            Button("Delete…", role: .destructive) { deleting = summary }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.s)
            }
            .frame(maxHeight: 180)
            .padding(.bottom, DS.Space.s)
        }
        .background(.bar)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Divider()
            StatusPill(text: "Simulator \(simulator.bootState.rawValue.lowercased())", tone: simulator.bootState.tone)
            StatusPill(text: idbPresent ? "idb ready" : "idb not installed", tone: idbPresent ? .success : .warning)
                .help(idbPresent ? "idb reads and drives the simulator" : "Install idb (see the README) to run cases on the simulator")
        }
        .padding([.horizontal, .bottom], DS.Space.m)
        .background(.bar)
    }

}

/// A small green dot that says something is happening, and says so to VoiceOver and on hover.
private struct ActivityDot: View {
    let label: String

    var body: some View {
        Circle().fill(StatusTone.success.tint).frame(width: 8, height: 8).help(label).accessibilityLabel(label)
    }
}
