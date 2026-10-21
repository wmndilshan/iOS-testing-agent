import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// Learned step skills. A person may let a quarantined skill be used again, or forget one.
struct SkillsView: View {
    @EnvironmentObject var library: SkillLibraryState
    @State private var confirmForget: SkillLibraryState.Row?
    @State private var query = ""

    private var shown: [SkillLibraryState.Row] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return library.rows }
        return library.rows.filter { [$0.testKey, $0.stepText, $0.bundleID].contains { $0.localizedCaseInsensitiveContains(needle) } }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
            detail.frame(minWidth: 340)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await library.reload() }
        .searchable(text: $query, placement: .toolbar, prompt: "Search skills")
        .confirmationDialog("Forget this skill?", isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }),
                            presenting: confirmForget) { row in
            Button("Forget", role: .destructive) { Task { await library.forget(row.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The step will be planned from scratch the next time it runs.") }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(query.isEmpty ? Format.count(library.rows.count, "skill") : "\(shown.count) of \(Format.count(library.rows.count, "skill"))")
                if library.quarantinedCount > 0 { StatusBadge(text: "\(library.quarantinedCount) quarantined", tone: .warning) }
                Spacer()
                Button { Task { await library.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload the skills").accessibilityLabel("Reload skills")
            }
            .padding(DS.Space.m)
            Divider()
            if library.rows.isEmpty {
                EmptyState(symbol: "books.vertical", title: "No skills yet", detail: "A step the agent completed and the judge accepted is remembered here, so the next run can repeat it.")
            } else if shown.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matching skills", detail: "Nothing matches “\(query)”.")
            } else {
                List(shown, selection: $library.selectedID) { row in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack {
                            Text("\(row.testKey) · step \(row.stepNumber)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if row.quarantined { StatusBadge(text: "Quarantined", tone: .warning, symbol: "exclamationmark.triangle.fill") }
                        }
                        Text(stepHeadline(row.stepText)).font(.callout).lineLimit(2)
                        HStack(spacing: DS.Space.m) {
                            Label("\(row.successes)", systemImage: "checkmark.circle.fill").foregroundStyle(StatusTone.success.tint)
                            Label("\(row.failures)", systemImage: "xmark.circle.fill").foregroundStyle(row.failures > 0 ? StatusTone.failure.tint : StatusTone.neutral.tint)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, DS.Space.hair).tag(row.id)
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button("Copy Case Key") { Clipboard.copy(row.testKey) }
                        if row.quarantined { Button("Use Again") { Task { await library.unquarantine(row.id) } } }
                        Button("Forget…", role: .destructive) { confirmForget = row }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let row = library.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("\(row.testKey) · step \(row.stepNumber)").font(.title3.weight(.semibold))
                        Text(row.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(stepHeadline(row.stepText)).font(.callout).textSelection(.enabled)
                    if row.quarantined {
                        Card(tone: .warning) {
                            Label("Quarantined after repeated failures. It is not replayed until you allow it again.", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(StatusTone.warning.tint)
                        }
                    }
                    SectionHeader("Actions")
                    ForEach(Array(row.actions.enumerated()), id: \.offset) { index, action in
                        Card { Text("\(index + 1). \(action)").font(.callout).textSelection(.enabled) }
                    }
                    if row.actions.isEmpty { Text("This step only checks the screen.").font(.callout).foregroundStyle(.secondary) }
                    SectionHeader("Usage")
                    Text("Learned \(Format.dateTime.string(from: row.learnedAt))" + (row.lastUsedAt.map { ", last used \(Format.dateTime.string(from: $0))" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if row.quarantined {
                            Button { Task { await library.unquarantine(row.id) } } label: { Label("Use Again", systemImage: "arrow.uturn.backward") }
                                .help("Take this skill out of quarantine")
                        }
                        Button(role: .destructive) { confirmForget = row } label: { Label("Forget", systemImage: "trash") }
                    }
                }
                .padding(DS.Space.l).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(symbol: "books.vertical", title: "Select a skill", detail: "See the actions it replays and how often it worked.")
        }
    }
}
