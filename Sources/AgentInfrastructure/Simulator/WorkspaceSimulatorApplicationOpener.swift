import AppKit
import AgentCore

/// Fixed Simulator.app opener. No executable or argument is caller-controlled.
@MainActor
public final class WorkspaceSimulatorApplicationOpener: SimulatorApplicationOpening {
    public init() {}
    public func openSimulatorApplication() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iphonesimulator"
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

