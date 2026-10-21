import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// The Agent section: describe a test scenario and watch a team of agents read the repository, write the case, run it and judge it.
struct AgentChatView: View {
    @EnvironmentObject private var chat: AgentChatState
    @EnvironmentObject private var workspace: WorkspaceState
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private static let contentWidth: CGFloat = 860
    private static let examples: [(icon: String, text: String)] = [
        ("safari", "In Safari, search Amazon for men's watches and open the first result"),
        ("person.badge.key", "Test the login screen with a wrong password, then a correct one"),
        ("switch.2", "Verify the Settings screen toggles can be switched on and off"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let approval = chat.deviceApproval {
                DeviceApprovalBanner(approval: approval, answer: chat.answerDevice)
                    .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.s)
            }
            if let prompt = chat.prompt {
                ApprovalBanner(prompt: prompt, info: prompt.caseKey.flatMap { chat.cases[$0] }, answer: chat.answer)
                    .frame(maxWidth: Self.contentWidth).padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            conversation
            VStack(spacing: DS.Space.s) {
                composer
            }
            .frame(maxWidth: Self.contentWidth)
            .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.l).padding(.top, DS.Space.s)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
        }
        // The pane is exactly as tall as the window gives it, whatever the conversation holds.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { composerFocused = true }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                FlowMenu()
                Button { if let path = RepositoryPicker.choose(startingAt: chat.repositoryPath) { chat.setRepositoryPath(path) } } label: {
                    Label(chat.repositoryPath.isEmpty ? "Choose repository…" : URL(fileURLWithPath: chat.repositoryPath).lastPathComponent, systemImage: "folder")
                }
                .labelStyle(.titleAndIcon)
                .help(chat.repositoryPath.isEmpty ? "Choose the local repository the agents read" : "\(chat.repositoryPath)\nClick to choose another")
                .accessibilityLabel("Repository")
                if chat.isBusy {
                    Button(role: .destructive) { chat.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop the agents (Cmd-.)")
                }
                Button { chat.requestClear() } label: { Label("Clear", systemImage: "trash") }
                    .help("Clear the conversation and what the agents remember").disabled(!chat.hasMessages)
            }
        }
        .confirmationDialog("Clear this conversation?", isPresented: $chat.isConfirmingClear, titleVisibility: .visible) {
            Button("Clear Conversation", role: .destructive) { chat.clear() }
            Button("Cancel", role: .cancel) { chat.cancelClear() }
        } message: { Text("The agents will also forget what they learned in it.") }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                if !chat.modelName.isEmpty { StatusBadge(text: chat.modelName, tone: .neutral, symbol: "cpu") }
                if chat.rememberedTurns > 0 {
                    StatusBadge(text: "Remembers \(chat.rememberedTurns) turn\(chat.rememberedTurns == 1 ? "" : "s")", tone: .neutral, symbol: "brain.head.profile")
                        .help("The agents are reminded of these earlier turns and of what they found, even after a restart. Clear the conversation to forget.")
                }
                if chat.usage.input > 0 {
                    StatusBadge(text: chat.usage.seconds > 0 ? "\(chat.usage.summary) · \(chat.usage.seconds)s" : chat.usage.summary, tone: .neutral, symbol: "gauge.with.dots.needle.33percent")
                        .help("Model tokens used by this conversation, and how many input tokens the provider served from its prompt cache")
                }
                Spacer()
            }
            HStack(spacing: DS.Space.m) {
                AgentStatusStrip(agents: chat.agents)
                Spacer(minLength: 0)
                if chat.repositoryStatus != .notSet { RepositoryStatusLine(status: chat.repositoryStatus) }
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(.bar)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Conversation

    private var conversation: some View {
        ConversationView(chat: chat, transcript: chat.transcript, onShowHistory: { workspace.show(.history) }, emptyState: AnyView(emptyState))
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 34)).foregroundStyle(DS.accent.opacity(0.8))
            Text("What should we test?").font(.title2.weight(.semibold))
            Text("A team of agents reads your repository, writes a test case, runs it on the simulator and checks the result.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            VStack(spacing: DS.Space.s) {
                ForEach(Self.examples, id: \.text) { example in
                    Button { draft = example.text; composerFocused = true } label: {
                        HStack(spacing: DS.Space.m) {
                            Image(systemName: example.icon).foregroundStyle(DS.accent).frame(width: 22)
                            Text(example.text).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(DS.Space.m).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dsSurface()
                }
            }
            .frame(maxWidth: 560).padding(.top, DS.Space.s)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            TextField("Describe the scenario to test…", text: $draft, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.plain).focused($composerFocused).autocorrectionDisabled()
                .padding(.vertical, DS.Space.s).padding(.leading, DS.Space.s)
                .onSubmit(send).accessibilityLabel("Message to the agents")
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(canSend ? DS.accent : Color.secondary.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain).disabled(!canSend).accessibilityLabel("Send").padding(.bottom, 4).padding(.trailing, 4)
        }
        .dsSurface(radius: DS.Radius.l, tint: composerFocused ? DS.accent : nil, borderOpacity: 0.6, wash: false)
    }

    private var canSend: Bool { !chat.isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        chat.send(draft)
        draft = ""
    }
}

/// The scrolling conversation. It alone watches the transcript, so a streamed word redraws this view and nothing around it.
///
/// It is a `List` (an NSTableView underneath): rows are recycled, each row is measured on its own, and the list always takes exactly the space
/// the pane gives it, whatever the conversation holds. (A `ScrollView` over a stack was measured at 1,767 pt inside a 786 pt window, which pushed the
/// whole window layout out of bounds.)
private struct ConversationView: View {
    let chat: AgentChatState
    @ObservedObject var transcript: AgentTranscript
    let onShowHistory: () -> Void
    let emptyState: AnyView
    /// True while the last row is on screen: only then does new content scroll into view by itself.
    @State private var atBottom = true
    /// How many of the newest items are shown; older ones sit behind a button.
    @State private var shownLimit = 120

    private static let contentWidth: CGFloat = 860

    var body: some View {
        let all = AgentTimeline.build(chat.messages, isBusy: chat.isBusy, flow: chat.flow, awaitingApproval: chat.isWaitingForPerson)
        let items = all.count > shownLimit ? Array(all.suffix(shownLimit)) : all
        ScrollViewReader { proxy in
            List {
                if chat.messages.isEmpty { listRow(emptyState) }
                if all.count > items.count {
                    listRow(Button("Show \(min(120, all.count - items.count)) earlier items (\(all.count - items.count) hidden)") { shownLimit += 120 }.buttonStyle(.link).frame(maxWidth: .infinity))
                }
                ForEach(items) { item in listRow(row(item, jump: { id in withAnimation { proxy.scrollTo(id, anchor: .top) } })) }
                if chat.isBusy && !chat.isWaitingForPerson && !hasLiveSection(items) {
                    listRow(HStack(spacing: DS.Space.s) { ProgressView().controlSize(.small); Text("Working…").font(.caption).foregroundStyle(.secondary) })
                }
                Color.clear.frame(height: 1).id("bottom")
                    .onAppear { atBottom = true }
                    .onDisappear { atBottom = false }
                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Scroll on the next turn of the run loop, after the new rows have been laid out.
            .onChange(of: transcript.revision) { _ in if atBottom { scrollToBottom(proxy) } }
            .onChange(of: chat.isBusy) { _ in if atBottom { scrollToBottom(proxy) } }
            .onChange(of: chat.isWaitingForPerson) { _ in scrollToBottom(proxy) }
            .onChange(of: chat.sendCount) { _ in scrollToBottom(proxy) }
            .overlay(alignment: .bottom) {
                if !atBottom && chat.hasMessages {
                    Button { scrollToBottom(proxy) } label: { Label("Jump to latest", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.small).padding(.bottom, DS.Space.m).shadow(radius: 4, y: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// One list row: centred column, no separators or background of its own.
    private func listRow<Content: View>(_ content: Content) -> some View {
        content
            .frame(maxWidth: Self.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: DS.Space.s, leading: DS.Space.l, bottom: DS.Space.s, trailing: DS.Space.l))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func hasLiveSection(_ items: [AgentTimelineItem]) -> Bool {
        guard let last = items.last, case .section(let section) = last else { return false }
        return section.isActive
    }

    @ViewBuilder private func row(_ item: AgentTimelineItem, jump: @escaping (UUID) -> Void) -> some View {
        switch item {
        case .plan(let plan): PlanCard(plan: plan, onSelect: jump).equatable()
        case .section(let section): AgentSectionCard(section: section).equatable()
        case .message(let message):
            switch message.kind {
            case .user: UserBubble(message: message)
            case .text: AssistantMessageView(message: message).equatable()
            case .thinking: ThinkingBlock(message: message).equatable()
            case .tool: ToolRow(message: message).equatable()
            case .testCase:
                if let info = message.caseInfo {
                    TestCaseCard(info: info, canRun: chat.canRunCases, fileExists: chat.caseFileExists(info.key), onRun: { chat.runNow(info) },
                                 onReveal: { NSWorkspace.shared.activateFileViewerSelecting([chat.caseFileURL(info.key)]) },
                                 onCopy: { Clipboard.copy(chat.caseFileText(info.key) ?? info.title) }).equatable()
                }
            case .verdict:
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    VerdictCard(message: message, caseKey: chat.lastCaseKey, openHistory: onShowHistory)
                    if chat.messages.last?.id == message.id, !chat.isBusy {
                        SuggestionChips(suggestions: AgentSuggestions.afterVerdict(message.text)) { chat.send($0) }
                    }
                }
            case .error: InlineBanner(tone: .failure, text: message.text)
            case .notice: Text(message.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            case .handoff: EmptyView()
            }
        }
    }
}
