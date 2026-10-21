import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// The Operate section: give the agents a task and watch them do it on the simulator, with the plan, what each agent is doing, and the live
/// screen. Pause to take over, then resume; save what was done as a test case.
struct OperateView: View {
    @EnvironmentObject private var operate: OperateState
    @EnvironmentObject private var workspace: WorkspaceState
    @State private var draft = ""
    @FocusState private var focused: Bool

    private static let examples: [(icon: String, text: String)] = [
        ("safari", "Open Safari, go to apple.com and tell me the first heading"),
        ("moon", "In Settings turn on dark mode, then turn it off"),
        ("line.3.horizontal.decrease.circle", "Open the filter menu of the lists screen and list its options"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                OperateHeader(operate: operate)
                Divider()
                if let approval = operate.deviceApproval {
                    DeviceApprovalBanner(approval: approval, answer: operate.answerDevice).padding(DS.Space.m)
                }
                if let reason = operate.blockedReason {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Label("The agents need you", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(StatusTone.warning.tint)
                        Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text("Click the simulator to do it yourself, then press Resume.").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.m).dsSurface(radius: DS.Radius.l, tint: StatusTone.warning.tint, borderOpacity: 0.55)
                    .padding(DS.Space.m)
                }
                content
                Divider()
                composer
            }
            Divider()
            LivePanel(operate: operate).frame(width: 300)
        }
    }

    // MARK: Content

    @State private var overrides: [Int: Bool] = [:]

    @ViewBuilder private var content: some View {
        if operate.phase == .idle, operate.entries.isEmpty {
            empty
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s) {
                        if !operate.team.isEmpty { TeamStrip(team: operate.team, activeAgent: operate.activeAgent).padding(.bottom, DS.Space.xs) }
                        if operate.goals.isEmpty, operate.isRunning { Label("Planning the goals…", systemImage: "list.bullet.clipboard").font(.callout).foregroundStyle(.secondary).padding(.vertical, DS.Space.s) }
                        ForEach(OperateCards.build(goals: operate.goals, entries: operate.entries)) { card in
                            GoalCardView(card: card, activeAgent: operate.activeAgent, override: overrides[card.id]) {
                                let current = overrides[card.id] ?? (card.goal?.state == .active || card.goal?.state == .failed || card.goal == nil)
                                overrides[card.id] = !current
                            }
                            .equatable().id(card.id)
                        }
                        if case .finished = operate.phase { ResultCard(operate: operate) { workspace.show(.tests) }.id("result") }
                    }
                    .padding(DS.Space.l).frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
                .onChange(of: operate.activeGoalNumber) { number in
                    guard let number else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(number, anchor: .center) }
                }
                .onChange(of: operate.phase) { phase in
                    if case .finished = phase { withAnimation { proxy.scrollTo("result", anchor: .bottom) } }
                }
            }
            .onChange(of: operate.activeSessionID) { _ in overrides = [:] }
        }
    }

    private var empty: some View {
        VStack(spacing: DS.Space.m) {
            Spacer()
            Image(systemName: WorkspaceSection.operate.symbolName).font(DS.Typography.heroSymbol).foregroundStyle(.secondary)
            Text("Give the agents a task").font(.title3.weight(.semibold))
            Text("They read the screen, tap, type and scroll on the simulator, check each step, and tell you what they found.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            VStack(spacing: DS.Space.s) {
                ForEach(Self.examples, id: \.text) { example in
                    Button { draft = example.text; focused = true } label: {
                        Label(example.text, systemImage: example.icon).frame(maxWidth: 440, alignment: .leading).padding(DS.Space.s)
                    }
                    .buttonStyle(.plain).dsSurface()
                }
            }
            if !operate.deviceAvailable {
                Label("idb was not found, so the simulator cannot be operated (see the README).", systemImage: "exclamationmark.triangle").font(.caption)
                    .foregroundStyle(StatusTone.warning.tint)
            }
            Spacer()
        }
        .padding(DS.Space.l).frame(maxWidth: .infinity)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let notice = operate.notice { Text(notice).font(.caption).foregroundStyle(StatusTone.warning.tint) }
            HStack(alignment: .bottom, spacing: DS.Space.s) {
                TextField("What should the agents do on the simulator?", text: $draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).focused($focused).padding(DS.Space.s).dsSurface(radius: DS.Radius.m, wash: false)
                    .onSubmit(run).disabled(operate.isRunning)
                Button(action: run) { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(operate.isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Toggle("Let the agents tap, type and scroll for this task without asking (destructive commands still ask)", isOn: $operate.letAgentOperate)
                .toggleStyle(.checkbox).font(.caption).disabled(operate.isRunning)
        }
        .padding(DS.Space.m)
    }

    private func run() {
        operate.start(draft)
        if operate.isRunning { draft = "" }
    }
}

/// The orchestrator, its leads and their workers: who is doing something now is highlighted.
struct TeamStrip: View {
    let team: [OperateLead]
    let activeAgent: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                chip("Orchestrator", active: activeAgent == "Orchestrator" || activeAgent == "Planner")
                ForEach(team, id: \.name) { lead in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lead.name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 3) { ForEach(lead.workers, id: \.self) { chip($0, active: $0 == activeAgent) } }
                    }
                }
            }
        }
    }

    private func chip(_ name: String, active: Bool) -> some View {
        Text(name).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(active ? DS.accent.opacity(0.25) : Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(active ? DS.accent : Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
