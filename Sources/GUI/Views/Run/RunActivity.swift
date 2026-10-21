import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// The live line above the steps: which step the runner is on, which try, and what it is doing this second. It comes from the runner's own
/// `step` and `activity` events, so it is right during a retry too (the failed step being tried again is the current step, not the next one).
struct RunActivityStrip: View {
    let currentStep: Int?
    let attempt: Int
    let stepCount: Int
    let activity: CaseRunState.Activity?
    let followLive: Bool
    let follow: () -> Void

    private var symbol: String {
        switch activity?.kind {
        case "plan": "brain"
        case "act": "hand.tap"
        case "judge": "checkmark.seal"
        case "settle": "hourglass"
        case "check": "checklist"
        case "replay": "arrow.triangle.2.circlepath"
        case "recovery": "arrow.clockwise"
        case "code": "chevron.left.forwardslash.chevron.right"
        default: "eye"
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ProgressView().controlSize(.small)
            if let currentStep {
                Text("Step \(currentStep)" + (stepCount > 0 ? " of \(stepCount)" : "")).font(.callout.weight(.semibold))
                if attempt > 1 { StatusBadge(text: "Retry \(attempt)", tone: .warning, symbol: "arrow.clockwise") }
            }
            Image(systemName: symbol).foregroundStyle(.secondary).imageScale(.small)
            Text(activity?.text ?? "Starting…").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: DS.Space.s)
            if let activity {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(activity.since)))) s").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            if !followLive, currentStep != nil {
                Button(action: follow) { Label("Follow live", systemImage: "scope") }.controlSize(.small)
                    .help("Jump to the step being worked on and follow it")
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
        .background(DS.accent.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working on step \(currentStep.map(String.init) ?? "?"): \(activity?.text ?? "starting")")
    }
}

/// What the run needs from the person, in the Run section itself: an approval of a critical action (with what it will do and to what), or a value
/// (a username, a password, test data). It replaces a modal sheet, which hid the run and the reason for the question.
struct RunPromptBanner: View {
    let prompt: CaseRunState.Prompt
    let answer: (String) -> Void
    @State private var text = ""
    @State private var choice: String?

    private var isApproval: Bool { prompt.kind == "approval" }
    private var lines: [String] { prompt.message.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: isApproval ? "hand.raised.fill" : (prompt.secure ? "lock.fill" : "text.cursor")).foregroundStyle(StatusTone.warning.tint)
                Text(prompt.title).font(.headline)
                if let step = prompt.step { StatusBadge(text: "Step \(step)", tone: .neutral) }
                Spacer()
                Text("The run is waiting for you").font(.caption).foregroundStyle(StatusTone.warning.tint)
                if let timeout = prompt.timeout { Countdown(since: prompt.since, seconds: timeout) }
            }
            if isApproval { approvalDetails } else { Text(prompt.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !prompt.message.lowercased().contains("never stored") { Text(why).font(.caption).foregroundStyle(.tertiary) }
            if isApproval {
                HStack {
                    Spacer()
                    Button("Deny") { answer("deny") }.keyboardShortcut(.cancelAction).accessibilityLabel("Deny this action")
                    Button("Approve") { answer("approve") }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityLabel("Approve this action")
                }
            } else if !prompt.options.isEmpty {
                choiceControls
            } else if prompt.isWaitOnly {
                HStack {
                    Spacer()
                    Button("I've done it") { answer("done") }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .help("Carry on now, without waiting for the screen to change").accessibilityLabel("I have done it, continue the run")
                }
            } else {
                HStack {
                    Group {
                        if prompt.secure { SecureField(prompt.title, text: $text) } else { TextField(prompt.title, text: $text) }
                    }
                    .textFieldStyle(.roundedBorder).onSubmit(submit).accessibilityLabel(prompt.title)
                    Button("Skip") { answer("") }.help("Continue without a value")
                    Button("Continue", action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(text.isEmpty)
                }
            }
        }
        .padding(DS.Space.m)
        .dsSurface(radius: DS.Radius.l, tint: StatusTone.warning.tint, borderOpacity: 0.55)
    }

    /// The agent's suggestion first, the other options below it, and a field for anything else the person wants to tell it.
    @ViewBuilder private var choiceControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Picker("Suggestion", selection: Binding(get: { choice ?? prompt.options.first ?? "" }, set: { choice = $0 })) {
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in Text(index == 0 ? "\(option)  (suggested)" : option).tag(option) }
            }
            .labelsHidden().pickerStyle(.menu).accessibilityLabel("Choose what the agent should do")
            HStack {
                TextField("or tell the agent something else", text: $text).textFieldStyle(.roundedBorder).onSubmit(submitChoice).accessibilityLabel("Tell the agent something else")
                Button("Continue", action: submitChoice).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func submitChoice() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        answer(typed.isEmpty ? (choice ?? prompt.options.first ?? "") : typed)
    }

    /// The approval text arrives as lines: what will be done, "Target: …", "Other labels on the same row: …".
    @ViewBuilder private var approvalDetails: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let first = lines.first { Text(first).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    private var why: String {
        if isApproval { return "This action looks destructive (it deletes, removes or logs out), so a person decides before it runs." }
        if !prompt.options.isEmpty { return "The agent suggests the first option. If nobody answers in time it takes the suggestion and says so in the report." }
        if prompt.isWaitOnly { return "Do it on the simulator and the run carries on by itself, or press the button. It stops if nobody does in time." }
        if prompt.secure { return "It is typed into the app and never stored." }
        return "The run needs this to carry on. Skip continues without it."
    }

    private func submit() { guard !text.isEmpty else { return }; answer(text) }
}

/// Time left before the run gives up waiting for the person, counted down once a second.
struct Countdown: View {
    let since: Date
    let seconds: Int

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let left = max(0, seconds - Int(context.date.timeIntervalSince(since)))
            Text("\(left / 60):\(String(format: "%02d", left % 60)) left").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("\(left) seconds left to answer")
        }
    }
}
