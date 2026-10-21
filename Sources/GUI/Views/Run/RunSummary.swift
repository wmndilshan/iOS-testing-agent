import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// Components shared by the live Run view and the read-only History view. They only show what they are given.

func outcomeTone(_ outcome: String) -> StatusTone {
    switch outcome {
    case "PASSED": return .success
    case "FAILED": return .failure
    case "RUNNING": return .active
    default: return .warning
    }
}

private func outcomeSymbol(_ outcome: String) -> String {
    switch outcome {
    case "PASSED": return "checkmark.circle.fill"
    case "FAILED": return "xmark.circle.fill"
    case "RUNNING": return "circle.dotted"
    default: return "exclamationmark.circle.fill"
    }
}

/// The text of a step without its test data and expected result.
func stepHeadline(_ text: String) -> String {
    text.components(separatedBy: " Test Data:").first?.components(separatedBy: " Expected:").first ?? text
}

/// What a person may do with a run that stopped: carry on from the step that stopped it, or run one step again.
struct ContinueActions {
    var canRun: Bool
    var failedStep: Int?
    var failedCount: Int
    var resume: (Int) -> Void
    var retry: (Int) -> Void
    var runFailed: () -> Void
}

struct RunSummaryHeader: View {
    let key: String
    let title: String
    let outcome: String?
    let isRunning: Bool
    let steps: [CaseRunState.Step]
    let startedAt: Date?
    let finishedAt: Date?
    var actions: ContinueActions? = nil
    var timing: RunTiming? = nil

    private var passed: Int { steps.filter { $0.status == .passed }.count }
    private var failed: Int { steps.filter { $0.status == .failed }.count }
    private var pending: Int { steps.filter { $0.status == .pending || $0.status == .running }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(key).font(.title3.weight(.semibold))
                    if !title.isEmpty { Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                if let outcome {
                    StatusBadge(text: outcome.capitalized, tone: outcomeTone(outcome), symbol: outcomeSymbol(outcome))
                } else if isRunning {
                    StatusBadge(text: "Running", tone: .active, symbol: "circle.dotted")
                }
            }
            ProgressBar(passed: passed, failed: failed, total: steps.count)
            HStack(spacing: DS.Space.l) {
                count("\(passed)", "passed", "checkmark.circle.fill", StatusTone.success.tint)
                count("\(failed)", "failed", "xmark.circle.fill", StatusTone.failure.tint)
                count("\(pending)", "pending", "circle", StatusTone.neutral.tint)
                Spacer()
                elapsed
            }
            if let timing, timing.totalSeconds > 0 { TimeBreakdown(timing: timing) }
            if let actions, actions.canRun, !isRunning, let outcome, outcome != "PASSED", let failed = actions.failedStep { continueBar(actions, failed: failed) }
        }
        .padding(DS.Space.l)
    }

    private func continueBar(_ actions: ContinueActions, failed: Int) -> some View {
        HStack(spacing: DS.Space.m) {
            Button { actions.resume(failed) } label: { Label("Resume from step \(failed)", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("Runs the case again from step \(failed), keeping the results before it. It checks first that the app is in front and logged in.")
            if actions.failedCount > 1 {
                Button { actions.runFailed() } label: { Label("Run failed steps only", systemImage: "arrow.counterclockwise") }
                    .controlSize(.small).help("Runs only the steps that failed, keeping the rest")
            }
            Text("Picks up where it stopped; the app should still be on the screen the earlier step left.").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.top, DS.Space.xs)
    }

    private func count(_ value: String, _ label: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(value) \(label)").foregroundStyle(.secondary)
        }
        .font(.subheadline).accessibilityElement(children: .combine).accessibilityLabel("\(value) \(label)")
    }

    @ViewBuilder private var elapsed: some View {
        if let startedAt {
            if let finishedAt {
                Label(Format.duration(finishedAt.timeIntervalSince(startedAt)), systemImage: "clock")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed \(Format.duration(finishedAt.timeIntervalSince(startedAt)))")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(Format.duration(context.date.timeIntervalSince(startedAt)), systemImage: "clock")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("Elapsed \(Format.duration(context.date.timeIntervalSince(startedAt)))")
                }
            }
        }
    }
}


/// Where the run's time went: one bar split by phase, with each phase's share. It shows what to speed up, and that a replayed step is cheap.
struct TimeBreakdown: View {
    let timing: RunTiming

    private static let order: [(key: String, title: String, color: Color)] = [
        ("plan", "Planning", DS.accent), ("judge", "Judge", DS.accent.opacity(0.6)), ("check", "Checks", DS.accent.opacity(0.35)),
        ("settle", "Waiting", Color.secondary.opacity(0.5)), ("replay", "Replay", Color.secondary.opacity(0.35)), ("other", "Other", Color.secondary.opacity(0.2)),
    ]

    var body: some View {
        let totals = timing.totals
        let sum = max(totals.values.reduce(0, +), 0.001)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Self.order, id: \.key) { item in
                        if let seconds = totals[item.key], seconds > 0 {
                            Rectangle().fill(item.color).frame(width: max(2, geo.size.width * seconds / sum))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)
            HStack(spacing: DS.Space.m) {
                ForEach(Self.order, id: \.key) { item in
                    if let seconds = totals[item.key], seconds / sum >= 0.03 {
                        HStack(spacing: 3) {
                            Circle().fill(item.color).frame(width: 6, height: 6)
                            Text("\(item.title) \(Int((seconds / sum * 100).rounded()))%").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Where the time went")
        .help("Where this run's time went, by phase")
    }
}
