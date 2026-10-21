import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// The test cases a person can browse and manage: search, create, edit, copy, delete, run.
struct TestsView: View {
    @EnvironmentObject var library: TestLibraryState
    @EnvironmentObject var caseRun: CaseRunState
    @EnvironmentObject var workspace: WorkspaceState
    @State private var query = ""
    @State private var confirmDelete: TestCaseRecord?
    @State private var bundleID = ""

    private var shown: [TestCaseRecord] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return library.records }
        return library.records.filter { [$0.key, $0.title].contains { $0.localizedCaseInsensitiveContains(needle) } }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
            detail.frame(minWidth: 380)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { library.reload() }
        .searchable(text: $query, placement: .toolbar, prompt: "Search test cases")
        .confirmationDialog("Delete this test case?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { record in
            Button("Delete", role: .destructive) { library.delete(key: record.key) }
            Button("Cancel", role: .cancel) {}
        } message: { record in Text("\(record.key) is removed from the TestCases folder. This cannot be undone.") }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(query.isEmpty ? Format.count(library.records.count, "test case") : "\(shown.count) of \(Format.count(library.records.count, "test case"))")
                Spacer()
                Button { library.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload").accessibilityLabel("Reload test cases")
                Button { library.startNew() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New test case").accessibilityLabel("New test case")
            }
            .padding(DS.Space.m)
            Divider()
            if library.records.isEmpty {
                EmptyState(symbol: "checklist", title: "No test cases yet", detail: "Create one here, or ask the agent to write one from a scenario.")
            } else if shown.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matching test cases", detail: "Nothing matches “\(query)”.")
            } else {
                List(shown, selection: Binding(get: { library.selectedKey }, set: { select($0) })) { record in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack {
                            Text(record.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            if !record.isEditable { StatusBadge(text: "Fetched", tone: .neutral) }
                            else if record.source == "agent" { StatusBadge(text: "Agent", tone: .active) }
                        }
                        Text(record.title).font(.callout).lineLimit(2)
                        Text(Format.count(record.steps.count, "step")).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, DS.Space.hair).tag(record.key)
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button("Run on Simulator") { run(record.key) }
                        Button("Copy Case Key") { Clipboard.copy(record.key) }
                        if record.isEditable { Button("Delete…", role: .destructive) { confirmDelete = record } }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func select(_ key: String?) {
        guard !library.isEditing else { return }
        library.selectedKey = key
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let draft = library.draft {
            TestCaseEditor(draft: Binding(get: { library.draft ?? draft }, set: { library.draft = $0 }), isNew: library.draftIsNew)
        } else if let record = library.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(record.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text("\(record.key) · \(record.source)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let message = library.errorMessage { Text(message).font(.callout).foregroundStyle(StatusTone.failure.tint) }
                    actions(for: record)
                    SectionHeader(Format.count(record.steps.count, "step"))
                    ForEach(Array(record.steps.enumerated()), id: \.element.id) { index, step in
                        Card {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Text("\(index + 1). \(step.action)").font(.callout.weight(.medium)).textSelection(.enabled)
                                if !step.data.isEmpty { Text(step.data).font(.caption.monospaced()).textSelection(.enabled) }
                                Label(step.expected, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(symbol: "checklist", title: "Select a test case", detail: "Pick one from the list, or create a new one with +.")
        }
    }

    private func actions(for record: TestCaseRecord) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                TextField("App id (optional)", text: $bundleID).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button { run(record.key) } label: { Label("Run on Simulator", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(caseRun.isRunning)
                    .help(caseRun.isRunning ? "A run is already in progress" : "Run this case on the simulator")
            }
            HStack(spacing: DS.Space.s) {
                if record.isEditable { Button("Edit") { library.startEditing() } }
                if record.isEditable { Button("Duplicate") { library.duplicateSelected() } }
                if let url = library.fileURL(for: record.key) { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                if record.isEditable { Button("Delete…", role: .destructive) { confirmDelete = record } }
            }
            if !record.isEditable { Text("Fetched from AIO; refresh it from there. Duplicate is not offered for fetched cases.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func run(_ key: String) {
        caseRun.start(key: key, bundleID: bundleID.isEmpty ? nil : bundleID)
        workspace.show(.run)
    }
}

/// Create or edit one case: key (new cases only), title, and an ordered list of steps.
private struct TestCaseEditor: View {
    @EnvironmentObject var library: TestLibraryState
    @Binding var draft: TestCaseRecord
    let isNew: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text(isNew ? "New test case" : "Edit \(draft.key)").font(.title3.weight(.semibold))
                if isNew {
                    TextField("Key, for example LOGIN-1", text: $draft.key).textFieldStyle(.roundedBorder)
                }
                TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
                SectionHeader("Steps")
                ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                    Card {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            HStack {
                                Text("Step \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button { library.moveStep(step.id, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move up")
                                Button { library.moveStep(step.id, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == draft.steps.count - 1).help("Move down")
                                Button { library.removeStep(step.id) } label: { Image(systemName: "trash") }.disabled(draft.steps.count == 1).help("Remove step")
                            }
                            .buttonStyle(.borderless)
                            TextField("What to do on screen", text: $draft.steps[index].action).textFieldStyle(.roundedBorder)
                            TextField("Text to type (optional)", text: $draft.steps[index].data).textFieldStyle(.roundedBorder)
                            TextField("What must be visible afterwards", text: $draft.steps[index].expected).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                Button { library.addStep() } label: { Label("Add Step", systemImage: "plus") }.disabled(draft.steps.count >= 25)
                if let message = library.errorMessage { Text(message).font(.callout).foregroundStyle(StatusTone.failure.tint) }
                HStack {
                    Button("Cancel") { library.cancelEditing() }.keyboardShortcut(.cancelAction)
                    Button("Save") { library.saveDraft() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
