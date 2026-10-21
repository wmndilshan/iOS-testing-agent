import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// Past runs from `.runs/cases`. Selecting one shows the same step list and detail as the Run view, read-only.
struct HistoryView: View {
    @EnvironmentObject var history: RunHistoryState
    @EnvironmentObject var run: CaseRunState
    @EnvironmentObject var workspace: WorkspaceState
    @State private var selectedStep: Int?
    @State private var query = ""
    @State private var outcomeFilter: RunOutcomeFilter = .all

    private var shown: [RunHistoryState.Entry] { history.filtered(outcome: outcomeFilter, query: query) }

    var body: some View {
        HSplitView {
            runList.frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
            detail.frame(minWidth: 480)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await history.load() }
        .searchable(text: $query, placement: .toolbar, prompt: "Search runs")
        .onChange(of: history.selectedID) { _ in selectedStep = history.selected?.steps.first(where: { $0.status == .failed })?.id }
    }

    private var runList: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(query.isEmpty && outcomeFilter == .all ? Format.count(history.entries.count, "run") : "\(shown.count) of \(Format.count(history.entries.count, "run"))")
                if history.isLoading { InlineSpinner() }
                Spacer()
                Button { Task { await history.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload the run history").accessibilityLabel("Reload run history")
            }
            .padding(DS.Space.m)
            if !history.entries.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Picker("Outcome", selection: $outcomeFilter) {
                        ForEach(RunOutcomeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Filter runs by outcome")
                    if let rate = history.passRate {
                        Text("\(Int((rate * 100).rounded()))% of finished runs passed").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.s)
            }
            Divider()
            if history.entries.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: history.isLoading ? "Loading runs…" : "No runs yet",
                           detail: history.isLoading ? nil : "Finished runs from the Run section are listed here.")
            } else if shown.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matching runs", detail: query.isEmpty ? "No \(outcomeFilter.rawValue.lowercased()) runs." : "Nothing matches “\(query)”.")
            } else {
                List(shown, selection: $history.selectedID) { entry in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack {
                            Text(entry.key).font(.callout.weight(.semibold))
                            Spacer()
                            StatusBadge(text: entry.outcome.capitalized, tone: outcomeTone(entry.outcome))
                        }
                        Text(entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: DS.Space.s) {
                            Text(Format.dateTime.string(from: entry.startedAt))
                            if let duration = entry.duration { Text("· " + Format.duration(duration)) }
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, DS.Space.hair).tag(entry.id)
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button("Copy Case Key") { Clipboard.copy(entry.key) }
                        Button("Reveal Report in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.reportURL]) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = history.selected {
            let steps = entry.steps
            VStack(spacing: 0) {
                RunSummaryHeader(key: entry.key, title: entry.title, outcome: entry.outcome, isRunning: false, steps: steps,
                                 startedAt: entry.startedAt, finishedAt: entry.report.finishedAt, actions: continueActions(for: entry, steps: steps), timing: entry.report.timing)
                Divider()
                HSplitView {
                    StepTimeline(steps: steps, selection: $selectedStep, timing: entry.report.timing)
                        .padding(.top, DS.Space.m).frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
                    StepDetailPane(steps: steps, thoughts: [], selection: selectedStep, evidenceRoot: entry.rootDirectory, actions: continueActions(for: entry, steps: steps))
                        .frame(minWidth: 280)
                }
            }
        } else {
            EmptyState(symbol: "clock.arrow.circlepath", title: "Select a run", detail: "See its steps, what failed and the screenshots.")
        }
    }

    /// Continuing a past run starts a new one in the Run section: the app, steps before the chosen one and their results come from the report.
    private func continueActions(for entry: RunHistoryState.Entry, steps: [CaseRunState.Step]) -> ContinueActions {
        let failed = steps.filter { $0.status == .failed }.map(\.id)
        func go(from step: Int, only: Bool = false, skipping: [Int] = [], keeping: [CaseRunState.Step]) {
            run.start(key: entry.key, bundleID: entry.report.bundleID, startStep: step, endStep: only ? step : nil, skipSteps: skipping, keeping: keeping)
            workspace.show(.run)
        }
        return ContinueActions(canRun: !run.isRunning, failedStep: entry.report.failedStep ?? failed.min(), failedCount: failed.count,
                               resume: { step in go(from: step, keeping: steps.filter { $0.id < step }) },
                               retry: { step in go(from: step, only: true, keeping: steps.filter { $0.id != step }) },
                               runFailed: {
                                   guard let first = failed.min() else { return }
                                   go(from: first, skipping: steps.map(\.id).filter { !failed.contains($0) && $0 >= first }, keeping: steps.filter { !failed.contains($0.id) })
                               })
    }
}
