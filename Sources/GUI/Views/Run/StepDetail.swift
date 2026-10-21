import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

private enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview", reasoning = "Reasoning", evidence = "Evidence"
    var id: String { rawValue }
}

struct StepDetailPane: View {
    let steps: [CaseRunState.Step]
    let thoughts: [CaseRunState.Thought]
    let selection: Int?
    /// Folder that evidence paths are relative to (`.runs/cases`).
    let evidenceRoot: URL
    var actions: ContinueActions? = nil
    /// The runner's reasoning and the actions of the selected step in the order they happened (live runs only; a past run keeps the actions).
    var timeline: [CaseRunState.TimelineItem] = []
    /// True while the runner works on the selected step: the timeline then shows what it is doing now and follows the newest line.
    var isLive = false
    var activity: CaseRunState.Activity? = nil
    @State private var tab: DetailTab = .overview

    var body: some View {
        if let id = selection, let step = steps.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.s) {
                    StatusIcon(status: step.status)
                    Text("Step \(step.id)").font(.headline)
                    Spacer()
                    if let actions, actions.canRun, step.status != .running {
                        Button { actions.retry(step.id) } label: { Label("Retry this step", systemImage: "arrow.clockwise") }
                            .controlSize(.small).help("Runs only step \(step.id) again, keeping every other result")
                        Button { actions.resume(step.id) } label: { Label("Resume from here", systemImage: "play.fill") }
                            .controlSize(.small).help("Runs the case from step \(step.id) to the end, keeping the results before it")
                    }
                }
                .padding([.horizontal, .top], DS.Space.l)
                Picker("Detail", selection: $tab) { ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityLabel("Step detail section")
                    .padding(DS.Space.l)
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            switch tab {
                            case .overview: overview(step)
                            case .reasoning: reasoning(step)
                            case .evidence: evidence(step)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding([.horizontal, .bottom], DS.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // A step being worked on is followed as it happens.
                    .onChange(of: timeline.count) { _ in if isLive && tab == .reasoning { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
                    .onChange(of: activity?.text) { _ in if isLive && tab == .reasoning { proxy.scrollTo("end", anchor: .bottom) } }
                }
                .onAppear { if isLive { tab = .reasoning } }
                .onChange(of: isLive) { live in if live { tab = .reasoning } }
            }
        } else {
            EmptyState(symbol: "list.bullet.rectangle", title: "Select a step", detail: "See what was done, what the planner and judge decided, and the screenshot.")
        }
    }

    private func overview(_ step: CaseRunState.Step) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(step.text).font(.subheadline).textSelection(.enabled)
            if let reason = step.failureReason {
                Card(tone: .failure) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Label("Why it failed", systemImage: "xmark.circle.fill").font(.subheadline.weight(.semibold))
                        Text(reason).font(.callout).textSelection(.enabled)
                    }
                }
            }
            SectionHeader("Actions and checks")
            if step.actions.isEmpty {
                Text("Nothing has run for this step yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(step.actions) { action in
                HStack(alignment: .top, spacing: DS.Space.s) {
                    StatusIcon(status: action.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.intent).font(.subheadline)
                        if !action.detail.isEmpty {
                            Text(action.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// What the runner thought and did for this step, in order: what it saw, what it planned, what it did, what the judge said, and what it decided.
    private func reasoning(_ step: CaseRunState.Step) -> some View {
        // Without a live timeline (a past run), the notes recorded for the step.
        let items = timeline.isEmpty ? thoughts.filter { $0.step == step.id }.map(CaseRunState.TimelineItem.thought) : timeline
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            if items.isEmpty && !isLive {
                Text("No reasoning was recorded for this step.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                switch item {
                case .thought(let thought): ThoughtRow(thought: thought)
                case .action(let action): ActionRow(action: action)
                }
            }
            if isLive {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(activity?.text ?? "Working…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, DS.Space.xs).accessibilityLabel("Now: \(activity?.text ?? "working")")
            }
        }
    }

    @ViewBuilder private func evidence(_ step: CaseRunState.Step) -> some View {
        if let path = step.evidence {
            EvidenceImage(url: evidenceRoot.appendingPathComponent(path), stepID: step.id)
        } else {
            Text("No screenshot was taken for this step.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// A step's screenshot, decoded off the main thread and cached (see `ImageCache`), so redraws while a run streams cost nothing.
private struct EvidenceImage: View {
    let url: URL
    let stepID: Int
    @State private var image: NSImage?
    @State private var missing = false
    @State private var isZoomed = false

    var body: some View {
        Group {
            if let image = ImageCache.cached(url) ?? image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 560)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(Color(nsColor: .separatorColor)))
                    .accessibilityLabel("Screenshot taken for step \(stepID)")
                    .onTapGesture { isZoomed = true }
                    .help("Click to enlarge")
                    .sheet(isPresented: $isZoomed) { ZoomedScreenshot(url: url, title: "Step \(stepID)") }
            } else if missing {
                Text("No screenshot was taken for this step.").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: ImageCache.version(of: url)) {
            missing = false
            let loaded = await ImageCache.load(url)
            image = loaded
            missing = loaded == nil
        }
    }
}

private enum ThoughtStyle {
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "observe": "eye"
        case "plan": "brain"
        case "act": "hand.tap"
        case "judge": "checkmark.seal"
        case "decide": "arrow.triangle.branch"
        case "check": "checklist"
        case "code": "chevron.left.forwardslash.chevron.right"
        case "recovery": "arrow.clockwise"
        default: "brain"
        }
    }

    static func title(_ kind: String) -> String {
        switch kind {
        case "observe": "Saw"
        case "plan": "Planned"
        case "act": "Did"
        case "judge": "Judge"
        case "decide": "Decided"
        case "check": "Checked"
        case "code": "Read the code"
        case "recovery": "Recovered"
        default: "Planned"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind {
        // Restrained: the verdicts and decisions stand out, a recovery warns, the rest stay quiet.
        case "judge", "decide": DS.accent
        case "recovery": DS.Palette.warning
        default: .secondary
        }
    }
}

private struct ThoughtRow: View {
    let thought: CaseRunState.Thought

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: ThoughtStyle.symbol(thought.kind)).foregroundStyle(ThoughtStyle.tint(thought.kind)).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(ThoughtStyle.title(thought.kind)).font(.caption.weight(.semibold)).foregroundStyle(ThoughtStyle.tint(thought.kind))
                    Text(thought.date, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(thought.text).font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActionRow: View {
    let action: CaseRunState.Action

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            StatusIcon(status: action.status).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text("Action").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(action.at, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(action.intent).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if !action.detail.isEmpty { Text(action.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .padding(DS.Space.s)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.s))
        .accessibilityElement(children: .combine)
    }
}

/// The screenshot at a larger size, with copy and save. Decoded at up to 2400 px (the cache keeps the smaller one for the step view).
private struct ZoomedScreenshot: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: DS.Space.m) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") { if let image { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) } }.disabled(image == nil)
                Button("Save…") { save() }.disabled(image == nil)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
                    .accessibilityLabel("Enlarged screenshot, \(title)")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(DS.Space.l)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 560, idealHeight: 820)
        .task { image = await ImageCache.load(url, maxPixels: 2400) }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let target = panel.url { try? FileManager.default.copyItem(at: url, to: target) }
    }
}
