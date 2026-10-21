import Foundation
import SwiftUI
import AgentCore

/// The sections of the main window's sidebar. Pure navigation vocabulary: no execution authority.
public enum WorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case run = "Run"
    case tests = "Tests"
    case history = "History"
    case skills = "Skills"
    case simulator = "Simulator"
    case operate = "Operate"
    case agent = "Agent"

    public var id: String { rawValue }
    public var title: String { rawValue }

    /// Cmd+N shortcut digit.
    public var shortcutDigit: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public var symbolName: String {
        switch self {
        case .run: return "play.circle"
        case .tests: return "checklist"
        case .history: return "clock.arrow.circlepath"
        case .skills: return "books.vertical"
        case .simulator: return "iphone"
        case .operate: return "cursorarrow.motionlines"
        case .agent: return "bubble.left.and.bubble.right"
        }
    }

    /// The list shown under the sections: chats belong to Agent, sessions to Operate, and the other sections have none.
    public enum SidebarList: Sendable, Equatable { case chats, sessions, none }
    public var sidebarList: SidebarList {
        switch self {
        case .agent: .chats
        case .operate: .sessions
        default: .none
        }
    }

    /// The section a `--tab` launch argument names. "Cases" is the old name of Run.
    public init?(launchName: String) {
        let name = launchName.lowercased()
        if name == "cases" { self = .run; return }
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == name }) else { return nil }
        self = match
    }
}

/// Restrained semantic tone. Green means verified/success only, orange pending or warning, red failure. The app maps it to colors.
public enum StatusTone: Sendable, Equatable {
    case neutral, active, success, warning, failure
}

/// UI-only navigation state for the main window. Holds no run, approval or execution state.
@MainActor
public final class WorkspaceState: ObservableObject {
    @Published public var section: WorkspaceSection = .run
    /// True while the Cmd+K command palette is showing.
    @Published public var isPaletteOpen = false

    public init() {}

    public func show(_ section: WorkspaceSection) { self.section = section }
}
