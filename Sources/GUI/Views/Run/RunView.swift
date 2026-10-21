import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// Run a test case by its number and watch it: command bar, summary, step timeline, step detail and the live device.
struct RunView: View {
    @EnvironmentObject var run: CaseRunState
    @EnvironmentObject var workspace: WorkspaceState
    @EnvironmentObject var simulator: SimulatorPaneModel
    @Environment(\.idbAvailable) private var idbAvailable
    @Environment(\.hasModelKey) private var hasModelKey
    @State private var key = ""
    @State private var bundleID = ""

    var body: some View {
        VStack(spacing: 0) {
            CommandBar(key: $key, bundleID: $bundleID, start: start)
            InstructionBar()
            Divider()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    content
                    if geo.size.width >= 900 {
                        Divider()
                        LivePreview().frame(width: 280)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if run.steps.isEmpty && !run.isRunning {
            if let message = run.errorMessage {
                EmptyState(symbol: "exclamationmark.triangle", title: "Could not start", detail: message)
            } else if !(idbAvailable && hasModelKey && simulator.bootState == .booted) {
                SetupChecklist(items: [
                    .init(title: "idb is installed", done: idbAvailable, hint: "Install it with Scripts/install.sh (it reads the screen and sends taps)."),
                    .init(title: "A simulator is booted", done: simulator.bootState == .booted, hint: "Open the Simulator section and boot a device."),
                    .init(title: "A model key is set", done: hasModelKey, hint: "Add GEMINI_API_KEY or DEEPSEEK_API_KEY to the project's .env file."),
                ])
            } else {
                EmptyState(symbol: "play.circle", title: "Run a test case",
                           detail: "Type a case number such as SAFARI-1, or choose one of the cases on this Mac. A case that is not on this Mac is fetched from the test case source.",
                           action: (title: "Have the agents write one", run: { workspace.show(.agent) }))
            }
        } else {
            VStack(spacing: 0) {
                if let message = run.errorMessage {
                    InlineBanner(tone: .failure, text: message).padding([.horizontal, .top], DS.Space.l)
                }
                if run.isRunning {
                    RunActivityStrip(currentStep: run.currentStep, attempt: run.currentAttempt, stepCount: run.steps.count, activity: run.currentActivity,
                                     followLive: run.followLive, follow: run.followCurrentStep)
                    Divider()
                }
                if let prompt = run.prompt {
                    RunPromptBanner(prompt: prompt, answer: run.answer).padding([.horizontal, .top], DS.Space.l)
                }
                RunSummaryHeader(key: run.caseKey, title: run.title, outcome: run.outcome, isRunning: run.isRunning, steps: run.steps,
                                 startedAt: run.startedAt, finishedAt: run.finishedAt, actions: continueActions, timing: run.timing)
                Divider()
                HSplitView {
                    StepTimeline(steps: run.steps, selection: Binding(get: { run.selectedStep }, set: { run.select($0) }), activity: run.currentActivity, timing: run.timing)
                        .padding(.top, DS.Space.m).frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
                    StepDetailPane(steps: run.steps, thoughts: run.thoughts, selection: run.selectedStep,
                                   evidenceRoot: run.projectRoot.appendingPathComponent(".runs/cases"), actions: continueActions,
                                   timeline: run.selectedStep.map { run.timeline(for: $0) } ?? [],
                                   isLive: run.isRunning && run.selectedStep != nil && run.selectedStep == run.currentStep, activity: run.currentActivity)
                        .frame(minWidth: 300)
                }
            }
        }
    }

    /// Carrying on from a run that stopped (only offered once it has ended and said which step stopped it).
    private var continueActions: ContinueActions {
        ContinueActions(canRun: !run.isRunning && !run.caseKey.isEmpty, failedStep: run.failedStep, failedCount: run.steps.filter { $0.status == .failed }.count,
                        resume: { run.resume(fromStep: $0) }, retry: { run.retry(step: $0) }, runFailed: { run.runFailedSteps() })
    }

    private func start() { run.start(key: key, bundleID: bundleID.isEmpty ? nil : bundleID) }
}

private struct CommandBar: View {
    @EnvironmentObject var run: CaseRunState
    @Binding var key: String
    @Binding var bundleID: String
    let start: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            TextField("Case number, e.g. SAFARI-1", text: $key)
                .textFieldStyle(.roundedBorder).frame(minWidth: 170, maxWidth: 240)
                .onSubmit(start).accessibilityLabel("Case number")
            let keys = run.availableCaseKeys()
            if !keys.isEmpty {
                Menu {
                    ForEach(keys, id: \.self) { candidate in Button(candidate) { key = candidate } }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Cases on this Mac").accessibilityLabel("Cases on this Mac")
            }
            TextField("App id (optional)", text: $bundleID)
                .textFieldStyle(.roundedBorder).frame(minWidth: 110, maxWidth: 170).accessibilityLabel("App bundle identifier")
            Picker("Autonomy", selection: $run.autonomy) {
                ForEach(CaseRunState.Autonomy.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340).disabled(run.isRunning)
            .help(run.isRunning ? "Autonomy can be changed between runs" : "How much the agent may do without asking").accessibilityLabel("Autonomy")
            Spacer(minLength: 0)
            if run.isRunning {
                Button(role: .destructive) { run.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .controlSize(.large).keyboardShortcut(".", modifiers: .command).help("Stop the run (Cmd-.)")
            } else {
                Button(action: start) { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command).help("Run the case (Cmd-R)")
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
    }
}

/// What the person tells the agent: before a run, instructions it keeps for the case ("use Test2 instead of Test1"); while it runs, a message it
/// hears before its next step. What the run is using is shown, with a way to forget it.
private struct InstructionBar: View {
    @EnvironmentObject var run: CaseRunState
    @State private var message = ""

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: run.isRunning ? "bubble.left.fill" : "text.bubble").foregroundStyle(.secondary).accessibilityHidden(true)
            if run.isRunning {
                TextField("Tell the agent something now, e.g. use Test2 instead of Test1", text: $message).textFieldStyle(.roundedBorder)
                    .onSubmit(send).accessibilityLabel("Tell the agent")
                Button("Send", action: send).disabled(message.trimmingCharacters(in: .whitespaces).isEmpty).help("The agent hears it before its next step")
            } else {
                TextField("Instructions for the agent (optional), e.g. use Test2 instead of Test1", text: $run.instructions).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Instructions for the agent")
            }
            if !run.guidance.isEmpty {
                Text("In use: \(run.guidance)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(run.guidance)
                if !run.isRunning {
                    Button(run.forgetSavedGuidance ? "Will be cleared" : "Clear") { run.forgetSavedGuidance = true }.controlSize(.small)
                        .disabled(run.forgetSavedGuidance).help("Forget the instructions saved for this case on the next run")
                }
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.s)
    }

    private func send() {
        run.tell(message)
        message = ""
    }
}

/// What must be in place before a case can run, shown in the Run section until it is.
private struct SetupChecklist: View {
    struct Item: Identifiable {
        let title: String
        let done: Bool
        let hint: String
        var id: String { title }
    }
    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Get ready to run").font(.title3.weight(.semibold))
            Text("A case needs these three things.").font(.callout).foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: DS.Space.m) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(item.done ? DS.Palette.success : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.medium))
                        if !item.done { Text(item.hint).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.title): \(item.done ? "done" : "missing"). \(item.done ? "" : item.hint)")
            }
        }
        .padding(DS.Space.xl).frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
