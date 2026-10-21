import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

@main
struct AutonomousTestingAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Navigation between the seven sections.
    @StateObject private var workspace = WorkspaceState()
    /// Simulator lifecycle and live picture.
    @StateObject private var simulator: SimulatorPaneModel
    /// The Run section: starts a test case run and shows its progress.
    @StateObject private var caseRun: CaseRunState
    /// The Agent section: a chat with the team of agents, and the repository setting they read.
    @StateObject private var agentChat: AgentChatState
    /// The History section: past runs from `.runs/cases`.
    @StateObject private var history: RunHistoryState
    /// The Skills section: learned step skills from `.skills/steps`.
    @StateObject private var skills: SkillLibraryState
    /// The Tests section: the case files, browsed and edited.
    @StateObject private var tests: TestLibraryState
    /// The Operate section: a graph of agents that operates the simulator.
    @StateObject private var operate: OperateState
    private let idbAvailable: Bool
    private let hasModelKey: Bool
    private let projectRoot: URL

    init() {
        // One composition root builds every piece of state; nothing else chooses where files live or which processes start.
        let root = AppCompositionRoot.fromEnvironment()
        _simulator = StateObject(wrappedValue: root.makeSimulatorPaneModel())
        _caseRun = StateObject(wrappedValue: root.makeCaseRunState())
        _agentChat = StateObject(wrappedValue: root.makeAgentChatState())
        _history = StateObject(wrappedValue: root.makeRunHistoryState())
        _skills = StateObject(wrappedValue: SkillLibraryState(store: root.makeStepSkillStore()))
        let library = TestLibraryState(store: TestCaseLibraryAdapter(projectRoot: root.projectRoot))
        _tests = StateObject(wrappedValue: library)
        _operate = StateObject(wrappedValue: root.makeOperateState(library: library))
        idbAvailable = root.isIDBAvailable
        hasModelKey = root.hasModelKey
        projectRoot = root.projectRoot
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(workspace)
                .environmentObject(simulator)
                .environmentObject(caseRun)
                .environmentObject(history)
                .environmentObject(skills)
                .environmentObject(tests)
                .environmentObject(agentChat)
                .environmentObject(operate)
                .environment(\.idbAvailable, idbAvailable)
                .environment(\.hasModelKey, hasModelKey)
                .tint(DS.accent)
                .frame(minWidth: 860, idealWidth: 1250, minHeight: 560, idealHeight: 800)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandMenu("Agent") {
                Button("New Conversation") { workspace.show(.agent); agentChat.newConversation() }
                    .keyboardShortcut("n", modifiers: .command).disabled(!agentChat.hasMessages)
                Button("Stop Agents") { agentChat.stop() }
                    .keyboardShortcut(".", modifiers: .command).disabled(!agentChat.isBusy)
                Divider()
                Button("Choose Repository…") {
                    workspace.show(.agent)
                    if let path = RepositoryPicker.choose(startingAt: agentChat.repositoryPath) { agentChat.setRepositoryPath(path) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Command Palette…") { workspace.isPaletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                ForEach(WorkspaceSection.allCases) { section in
                    Button(section.title) { workspace.show(section) }
                        .keyboardShortcut(KeyEquivalent(Character(String(section.shortcutDigit))), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsRootView(projectRoot: projectRoot).environmentObject(agentChat)
                .environment(\.idbAvailable, idbAvailable).environment(\.hasModelKey, hasModelKey)
        }
    }
}

private struct IDBAvailableKey: EnvironmentKey {
    static let defaultValue = false
}

private struct HasModelKeyKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether a model key is configured. Decided once at launch.
    var hasModelKey: Bool {
        get { self[HasModelKeyKey.self] }
        set { self[HasModelKeyKey.self] = newValue }
    }

    /// Whether `idb` (the tool that reads and drives the simulator) is installed. Decided once at launch.
    var idbAvailable: Bool {
        get { self[IDBAvailableKey.self] }
        set { self[IDBAvailableKey.self] = newValue }
    }
}
