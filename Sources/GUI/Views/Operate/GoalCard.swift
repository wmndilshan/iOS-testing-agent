import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// One goal of the plan: its state, what was done for it in words, the check's verdict, and the reasoning behind a disclosure. The active goal
/// opens by itself, a failed one stays open, a passed one folds to a single line.
struct GoalCardView: View, Equatable {
    let card: OperateGoalCard
    let activeAgent: String
    /// The person's choice for this card, if they made one.
    let override: Bool?
    let toggle: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.card == b.card && a.activeAgent == b.activeAgent && a.override == b.override }

    private var state: OperateGoal.State { card.goal?.state ?? .active }
    private var isOpen: Bool { override ?? (state == .active || state == .failed || card.goal == nil) }
    private var tone: StatusTone { state == .done ? .success : state == .failed ? .failure : state == .active ? .active : .neutral }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button(action: toggle) { header }.buttonStyle(.plain)
            if !isOpen, state == .done, !card.evidence.isEmpty {
                Text(card.evidence).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 26)
            }
            if isOpen { content.padding(.leading, 26) }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(radius: DS.Radius.m, tint: state == .active ? DS.accent : state == .failed ? StatusTone.failure.tint : nil, borderOpacity: state == .active ? 0.5 : 0.35, wash: state != .pending && state != .done)
        .opacity(state == .pending ? 0.7 : 1)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.callout.weight(.medium)).foregroundStyle(state == .pending ? .secondary : .primary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let goal = card.goal, goal.attempts > 1 {
                    Text("Attempt \(goal.attempts)").font(.caption2.weight(.semibold)).foregroundStyle(StatusTone.warning.tint)
                }
            }
            Spacer(minLength: 0)
            if let goal = card.goal, !goal.kind.isEmpty { Text(goal.kind.capitalized).font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(card.title), \(state.rawValue)")
        .accessibilityHint(isOpen ? "Collapse" : "Expand")
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .active: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(tone.tint)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(tone.tint)
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let expected = card.goal?.expected, !expected.isEmpty {
                Label(expected, systemImage: "scope").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon).fixedSize(horizontal: false, vertical: true)
            }
            if card.lines.isEmpty, state == .active {
                Text(activeAgent.isEmpty ? "Starting…" : "\(activeAgent) is working…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(card.lines) { line in LineRow(line: line) }
            if !card.reasoning.isEmpty {
                DisclosureGroup {
                    Text(card.reasoning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, DS.Space.xs)
                } label: { Label("Reasoning", systemImage: "brain").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct LineRow: View {
    let line: OperateActivityLine

    private var tint: Color {
        switch line.outcome {
        case .failed, .notPassed: StatusTone.failure.tint
        case .passed: StatusTone.success.tint
        case .ok, .running, .info: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: line.symbol).font(.caption).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.text).font(.callout).foregroundStyle(line.outcome == .notPassed || line.outcome == .passed ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if line.outcome == .passed || line.outcome == .notPassed {
                    Text(line.outcome == .passed ? "Passed" : "Not passed").font(.caption2.weight(.semibold)).foregroundStyle(tint)
                }
            }
            Spacer(minLength: 0)
            if line.outcome == .running { ProgressView().controlSize(.mini) }
            else if line.outcome == .failed { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(tint) }
            if let ms = line.milliseconds, ms >= 100 { Text(Format.duration(Double(ms) / 1000)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .accessibilityElement(children: .combine)
    }
}
