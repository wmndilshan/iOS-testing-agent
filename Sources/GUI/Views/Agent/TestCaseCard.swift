import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// The test case the CaseAuthor saved, shown as a document: title, app, every step with its data and expected result, and what can be done with it.
struct TestCaseCard: View, Equatable {
    let info: AgentCaseInfo
    let canRun: Bool
    /// False when TestCases/<key>.json is gone: the card says so and does not offer a run that could only fail.
    let fileExists: Bool
    let onRun: () -> Void
    let onReveal: () -> Void
    let onCopy: () -> Void
    @State private var showAll = false

    nonisolated static func == (a: TestCaseCard, b: TestCaseCard) -> Bool { a.info == b.info && a.canRun == b.canRun && a.fileExists == b.fileExists }

    private static let collapsedSteps = 6

    private var visibleSteps: [AgentCaseInfo.Step] { showAll ? info.steps : Array(info.steps.prefix(Self.collapsedSteps)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: "checklist").font(.title2).foregroundStyle(DS.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(info.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.s) {
                        Chip(text: info.key, monospaced: true)
                        if !info.bundleID.isEmpty { Chip(text: info.bundleID, symbol: "app.badge") }
                        Chip(text: "\(info.steps.count) step\(info.steps.count == 1 ? "" : "s")", symbol: "list.number")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.m)
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(visibleSteps, id: \.number) { step in StepRow(step: step) }
                if info.steps.count > Self.collapsedSteps {
                    Button(showAll ? "Show fewer steps" : "Show all \(info.steps.count) steps") { withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() } }
                        .buttonStyle(.link).font(.callout)
                }
            }
            .padding(DS.Space.m)
            Divider()
            HStack(spacing: DS.Space.s) {
                Button(action: onRun) { Label("Run on simulator", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(!canRun || !fileExists).accessibilityLabel("Run this test case on the simulator")
                    .help(!fileExists ? "TestCases/\(info.key).json is missing" : canRun ? "Runs the case in the Run section" : "Wait for the agents or the current run to finish")
                Button(action: onReveal) { Label("Show in Finder", systemImage: "folder") }.accessibilityLabel("Show the test case file in Finder")
                Button(action: onCopy) { Label("Copy JSON", systemImage: "doc.on.doc") }.accessibilityLabel("Copy the test case")
                Spacer()
                if !fileExists {
                    Label("File not found in TestCases/", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(StatusTone.warning.tint)
                }
            }
            .controlSize(.regular).padding(DS.Space.m)
        }
        .dsSurface(radius: DS.Radius.l, tint: .accentColor, borderOpacity: 0.35, wash: false)
    }
}

private struct StepRow: View {
    let step: AgentCaseInfo.Step

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Text("\(step.number)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(DS.accent)
                .frame(width: 22, height: 22).background(DS.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(step.action).fixedSize(horizontal: false, vertical: true)
                if !step.data.isEmpty {
                    Text(step.data).font(DS.Typography.monoCaption).padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.hair)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.s))
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Image(systemName: "checkmark.circle").imageScale(.small)
                    Text(step.expected).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
