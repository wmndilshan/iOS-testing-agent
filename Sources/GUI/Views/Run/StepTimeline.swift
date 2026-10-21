import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

struct StepTimeline: View {
    let steps: [CaseRunState.Step]
    @Binding var selection: Int?
    /// What the runner is doing now, shown on the step it belongs to.
    var activity: CaseRunState.Activity? = nil
    /// Where the time went. A step with a recorded time shows a bar as long as its share of the slowest step.
    var timing: RunTiming? = nil

    var body: some View {
        let slowest = timing?.steps.values.map(\.seconds).max() ?? 0
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(steps) { step in
                        Button { selection = step.id } label: { StepCard(step: step, isSelected: selection == step.id, activity: step.isCurrent ? activity?.text : nil,
                                                                    seconds: timing?.steps[String(step.id)]?.seconds, slowest: slowest) }
                            .buttonStyle(.plain)
                            .id(step.id)
                            .accessibilityLabel("Step \(step.id), \(step.status.rawValue). \(stepHeadline(step.text))")
                            .accessibilityAddTraits(selection == step.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.l)
            }
            .onChange(of: selection) { id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

/// One step as a flat row: a small status mark, the step in plain type, and one quiet line under it. The selected row is shaded, nothing is boxed.
private struct StepCard: View {
    let step: CaseRunState.Step
    let isSelected: Bool
    let activity: String?
    var seconds: Double? = nil
    var slowest: Double = 0

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            StatusIcon(status: step.status).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.xs) {
                    Text("Step \(step.id)").font(.caption).foregroundStyle(.secondary)
                    if step.isCurrent { Text(step.attempt > 1 ? "· retrying (attempt \(step.attempt))" : "· working").font(.caption).foregroundStyle(.secondary) }
                }
                Text(stepHeadline(step.text)).font(.subheadline).lineLimit(3).multilineTextAlignment(.leading)
                if let activity {
                    Text(activity).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                } else if let reason = step.failureReason, !step.isCurrent {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                } else if step.status == .unsupported, let note = step.actions.first(where: { $0.status == .unsupported })?.detail {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                if let seconds, seconds > 0, slowest > 0 { DurationBar(seconds: seconds, share: seconds / slowest, tint: step.status == .failed ? DS.Palette.failure : DS.accent) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.s).fill(isSelected ? DS.accent.opacity(0.14) : .clear))
        .overlay(alignment: .bottom) { if !isSelected { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 0.5).padding(.leading, 34) } }
        .contentShape(Rectangle())
    }
}

/// A thin bar and the time next to it: how long a step took compared with the slowest step of the run.
private struct DurationBar: View {
    let seconds: Double
    let share: Double
    let tint: Color

    var body: some View {
        HStack(spacing: DS.Space.s) {
            GeometryReader { proxy in
                Capsule().fill(tint.opacity(0.55)).frame(width: max(3, proxy.size.width * min(share, 1)), height: 3)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 8)
            Text(Format.duration(seconds)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Took \(Format.duration(seconds))")
    }
}
