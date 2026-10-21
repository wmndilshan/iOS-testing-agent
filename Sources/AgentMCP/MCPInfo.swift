import Foundation

/// The server's identity and the advice it gives a client's model.
public enum MCPInfo {
    public static let version = "1.0.0"

    public static let server = MCPServerInfo(name: "autonomous-testing-agent", version: version, instructions: """
        Drives an iOS simulator and runs test cases. Loop: device_observe read_screen (a short list of controls with #numbers) → act with device_input \
        (tap by handle or label, type_text, swipe, scroll) → read_screen again to check. Use device_observe look only when the list cannot answer. \
        Destructive commands (uninstall, erase, clear data) need confirm=true after the person agrees. Cases: list_cases, read_case, write_case, \
        run_case (minutes; needs TEST_USER_USERNAME/TEST_USER_PASSWORD in the server's environment for logins), list_runs, get_report.
        """)
}
