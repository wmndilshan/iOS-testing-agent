import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// The end of an Operate task as a short report: one outcome line, what was found, what did not pass, and the figures, as label and value rows.
/// The goal cards above already say what was done, so this does not repeat them. Colour appears once, as the dot beside the outcome.
struct ResultCard: View {
    @ObservedObject var operate: OperateState
    let openTests: () -> Void

    private var passed: Bool { operate.phase == .finished(done: true) }
    private var doneCount: Int { operate.goals.filter { $0.state == .done }.count }
    private static let labelWidth: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            row("Outcome") {
                // The dot hangs in the gutter so the outcome text lines up with the values below it.
                Text(passed ? "Completed, \(doneCount) of \(operate.goals.count) goals" : "Not completed, \(doneCount) of \(operate.goals.count) goals")
                    .overlay(alignment: .leading) { Circle().fill(passed ? DS.Palette.success : DS.Palette.failure).frame(width: 6, height: 6).offset(x: -12) }
            }
            if !operate.findings.isEmpty {
                row(operate.findings.count == 1 ? "Finding" : "Findings") {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(Array(operate.findings.enumerated()), id: \.offset) { _, finding in Text(finding).textSelection(.enabled) }
                    }
                }
            }
            if !operate.unmetGoals.isEmpty {
                row("Not met") {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(Array(operate.unmetGoals.enumerated()), id: \.offset) { _, goal in Text(goal).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
            }
            row("Duration") { Text(Format.duration(TimeInterval(operate.usage.seconds))).monospacedDigit() }
            if !operate.workerTimeSummary.isEmpty { row("Time by agent") { Text(operate.workerTimeSummary) } }
            row("Model calls") { Text("\(operate.usage.calls)").monospacedDigit() }
            row("Tokens") { Text((operate.usage.input + operate.usage.output).formatted()).monospacedDigit() }
            if let key = operate.savedCaseKey { row("Test case", last: true) { Text(key).font(DS.Typography.monoCaption) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(radius: DS.Radius.m)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            Text("Result").font(.subheadline.weight(.semibold))
            Spacer()
            action("Copy") { Clipboard.copy(operate.resultText) }
            if operate.savedCaseKey != nil {
                action("Open in Tests", openTests)
            } else if operate.canSaveAsCase {
                action("Save as test case") { operate.saveAsTestCase() }.help("\(operate.plannedStepCount) steps from what was done")
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(title).font(.caption) }.buttonStyle(.plain).foregroundStyle(DS.accent)
    }

    private func row<Value: View>(_ label: String, last: Bool = false, @ViewBuilder _ value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: Self.labelWidth, alignment: .leading)
            value().font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 0.5).padding(.leading, DS.Space.m) } }
        .accessibilityElement(children: .combine)
    }
}
