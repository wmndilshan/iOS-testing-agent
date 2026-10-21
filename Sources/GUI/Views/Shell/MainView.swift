import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// The window: a sidebar of five sections and the selected one.
struct MainView: View {
    @EnvironmentObject private var workspace: WorkspaceState
    @EnvironmentObject private var simulator: SimulatorPaneModel
    @EnvironmentObject private var caseRun: CaseRunState
    @EnvironmentObject private var agentChat: AgentChatState
    @EnvironmentObject private var operate: OperateState
    @EnvironmentObject private var history: RunHistoryState
    @EnvironmentObject private var tests: TestLibraryState

    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            Group {
                switch workspace.section {
                case .run: RunView()
                case .tests: TestsView()
                case .history: HistoryView()
                case .skills: SkillsView()
                case .simulator: SimulatorView()
                case .operate: OperateView()
                case .agent: AgentChatView()
                }
            }
            // The pane's minimum height is measured at its minimum width. Without a real minimum width, wrapping text (an approval message, a
            // long label) is measured one word per line and the pane demands thousands of points of height, so the whole split view grows past
            // the window and its top and bottom are clipped.
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        // A question for the person must be seen: bring the chat forward, badge the dock when the app is in the background.
        .onChange(of: agentChat.isWaitingForPerson) { waiting in
            if waiting {
                workspace.show(.agent)
                if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
                NSApp.dockTile.badgeLabel = "1"
            } else {
                NSApp.dockTile.badgeLabel = nil
            }
        }
        // A device command in Operate waits for the person.
        .onChange(of: operate.isWaitingForPerson) { waiting in
            if waiting {
                workspace.show(.operate)
                if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
                NSApp.dockTile.badgeLabel = "1"
            } else if !agentChat.isWaitingForPerson && caseRun.prompt == nil {
                NSApp.dockTile.badgeLabel = nil
            }
        }
        // The run needs an approval or a value: bring it forward, and tell the person if the app is in the background.
        .onChange(of: caseRun.prompt != nil) { waiting in
            if waiting {
                workspace.show(.run)
                if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
                NSApp.dockTile.badgeLabel = "1"
            } else if !agentChat.isWaitingForPerson {
                NSApp.dockTile.badgeLabel = nil
            }
        }
        .onChange(of: caseRun.errorMessage) { message in LaunchHarness.trace("RUNERROR \(message ?? "nil")") }
        .onChange(of: workspace.section) { section in LaunchHarness.trace("SECTION now \(section.rawValue)") }
        .sheet(isPresented: $workspace.isPaletteOpen) { CommandPaletteView() }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .onAppear {
            // Take the keyboard: a window that is not key cannot receive typing, whatever its text fields look like.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
            }
            agentChat.bind(workspace: workspace, caseRun: caseRun)
            LaunchHarness.windowDidAppear(workspace: workspace, caseRun: caseRun, agentChat: agentChat, operate: operate, history: history, tests: tests)
        }
        .task { await simulator.refresh(); simulator.startMonitoring() }
    }

    private var windowTitle: String {
        caseRun.caseKey.isEmpty ? "Autonomous Testing Agent" : "Case \(caseRun.caseKey)"
    }

    private var windowSubtitle: String {
        if agentChat.isWaitingForPerson { return "Waiting for your approval" }
        if caseRun.prompt != nil { return "Waiting for your answer" }
        if caseRun.isRunning { return "Running" }
        return caseRun.outcome?.capitalized ?? ""
    }
}
