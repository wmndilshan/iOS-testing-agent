import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// The workflow of a turn as a checklist: each specialist, where it stands, and how long it took. Click a step to jump to its work.
struct PlanCard: View, Equatable {
    let plan: AgentPlan
    let onSelect: (UUID) -> Void
    @State private var collapsed: Bool?

    nonisolated static func == (a: PlanCard, b: PlanCard) -> Bool { a.plan == b.plan }

    private var isCollapsed: Bool { collapsed ?? plan.isFinished }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { collapsed = !isCollapsed } } label: {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "list.bullet.clipboard").foregroundStyle(DS.accent)
                    Text("Plan").font(.callout.weight(.semibold))
                    Text("\(plan.completedCount) of \(plan.steps.count) done" + (plan.seconds > 0 ? " · \(plan.seconds)s" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(plan.completedCount), total: Double(max(plan.steps.count, 1)))
                        .progressViewStyle(.linear).frame(maxWidth: 140)
                    Spacer(minLength: 0)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").imageScale(.small).foregroundStyle(.tertiary)
                }
                .padding(DS.Space.m).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Plan, \(plan.completedCount) of \(plan.steps.count) steps done")

            if !isCollapsed {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        PlanStepRow(step: step, isLast: index == plan.steps.count - 1, onSelect: onSelect)
                    }
                }
                .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
            }
        }
        .dsSurface(radius: DS.Radius.l, borderOpacity: 0.55)
    }
}

private struct PlanStepRow: View {
    let step: AgentPlan.Step
    let isLast: Bool
    let onSelect: (UUID) -> Void

    private var symbol: (name: String, tint: Color) {
        switch step.state {
        case .pending: ("circle", Color.secondary.opacity(0.6))
        case .working: ("circle.dotted", DS.accent)
        case .waitingForApproval: ("hand.raised.fill", StatusTone.warning.tint)
        case .done: ("checkmark.circle.fill", StatusTone.success.tint)
        case .issues: ("exclamationmark.circle.fill", StatusTone.warning.tint)
        case .skipped: ("minus.circle", Color.secondary.opacity(0.5))
        }
    }

    private var detail: String {
        switch step.state {
        case .pending: "Waiting"
        case .working: "Working…"
        case .waitingForApproval: "Waiting for your approval"
        case .done, .issues:
            [step.seconds.map { "\($0)s" }, step.toolCalls > 0 ? Format.count(step.toolCalls, "tool call") : nil, step.state == .issues ? "some tool calls failed" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        case .skipped: "Not needed"
        }
    }

    var body: some View {
        Button { if let id = step.sectionID { onSelect(id) } } label: {
            HStack(alignment: .top, spacing: DS.Space.m) {
                // The checklist's spine: a marker per step joined by a thin line.
                VStack(spacing: 0) {
                    Group {
                        if step.state == .working { ProgressView().controlSize(.small).scaleEffect(0.8) }
                        else { Image(systemName: symbol.name).foregroundStyle(symbol.tint) }
                    }
                    .frame(width: 18, height: 18)
                    if !isLast { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).frame(maxHeight: .infinity) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.agent).font(.callout.weight(.medium)).foregroundStyle(step.state == .pending || step.state == .skipped ? .secondary : AgentStyle.color(step.agent))
                        .strikethrough(step.state == .skipped, color: .secondary)
                    Text(step.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.s)
                Text(detail).font(.caption).foregroundStyle(step.state == .waitingForApproval ? StatusTone.warning.tint : .secondary)
            }
            .padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(step.sectionID == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.agent): \(detail)")
    }
}

/// One-click follow-ups under a verdict.
struct SuggestionChips: View {
    let suggestions: [String]
    let send: (String) -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(suggestions, id: \.self) { text in
                Button { send(text) } label: { Label(text, systemImage: "arrow.turn.down.right") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }
}
