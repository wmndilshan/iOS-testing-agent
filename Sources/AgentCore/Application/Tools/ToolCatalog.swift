import Foundation

/// The trusted, static catalog of every tool the system can run: one `ToolDescriptor` per tool.
///
/// The application owns this table. A model, a proposal or a call's arguments can never declare a tool
/// read-only or extend its input schema, and mutability is never inferred from a name at runtime. An
/// unknown tool has no descriptor and is refused (fail closed). The LLM-facing tool declarations are
/// *generated* from these descriptors, so the schema the model sees and the schema that is enforced
/// cannot drift apart.
///
/// Adding a tool means adding one descriptor here plus its handler in `ToolRegistry`; a new descriptor
/// grants no authority by itself: mutating tools still require a `DispatchAuthorizer.Authorized` proof.
public enum ToolCatalog {

    public static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: "get_project_info", canonicalName: "host.project_info", version: 1, category: .project, platform: .host, risk: .readOnly, live: .notApplicable,
            summary: "Returns basic information about the current project, such as the project name, Package.swift presence, available source files, and project structure.",
            input: [],
            output: "payload: project structure summary"
        ),
        ToolDescriptor(
            name: "get_app_state", canonicalName: "ios.app_state", version: 1, category: .observation, platform: .ios, risk: .readOnly, live: .liveVerified,
            summary: "Returns the current runtime state of the application (runningForeground, runningBackground, notRunning).",
            input: [],
            output: "summary + fresh observation"
        ),
        ToolDescriptor(
            name: "get_accessibility_tree", canonicalName: "ios.accessibility_tree", version: 1, category: .observation, platform: .ios, risk: .readOnly, live: .liveVerified,
            summary: "Captures a bounded, sanitized snapshot of the visible UI elements in the application with stable element IDs.",
            input: [],
            output: "summary + fresh observation (the standard Observation model)"
        ),
        ToolDescriptor(
            name: "get_element_details", canonicalName: "ios.element_details", version: 1, category: .observation, platform: .ios, risk: .readOnly, live: .liveVerified,
            summary: "Retrieves detailed properties for an element identified in the active snapshot.",
            input: [
                .init("snapshotID", .string, required: true, "The active snapshot ID."),
                .init("elementID", .string, required: true, "The element identifier.")
            ],
            output: "payload: element facts from the trusted snapshot"
        ),
        ToolDescriptor(
            name: "wait_for_element", canonicalName: "ios.wait_for_element", version: 1, category: .synchronization, platform: .ios, risk: .readOnly, live: .implementedNotLiveVerified,
            summary: "Waits for an element with the given identifier to appear in the UI hierarchy.",
            input: [
                .init("identifier", .string, required: true, "The accessibility identifier to wait for."),
                .init("timeoutSeconds", .number, required: false, "Maximum wait duration in seconds (0.1 to 60.0).")
            ],
            output: "summary + the observation that satisfied the wait; times out with `timeout`"
        ),
        ToolDescriptor(
            name: "capture_screenshot", canonicalName: "ios.screenshot", version: 1, category: .capture, platform: .ios, risk: .readOnly, live: .liveVerified,
            summary: "Captures visual screenshot evidence when visual layout verification is necessary or the accessibility tree is ambiguous.",
            input: [
                .init("reason", .string, required: false, "Explanation of why screenshot fallback is needed.")
            ],
            output: "summary + artifact reference (path only when no artifact store is configured)"
        ),
        ToolDescriptor(
            name: "inspect_elements", canonicalName: "ios.inspect", version: 1, category: .observation, platform: .ios, risk: .readOnly, live: .liveVerified,
            summary: "Asserts the trusted scenario's accessibility expectations against a fresh observation without state mutation.",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID.")
            ,
                .init("elementID", .string, required: false, "Target element chosen by trusted validation; the inspection covers the whole snapshot.")
            ],
            output: "summary + assertion outcomes"
        ),
        ToolDescriptor(
            name: "tap_element", canonicalName: "ios.tap", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Taps an element identified in the current snapshot.",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The element ID from the snapshot.")
            ],
            output: "summary; a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "double_tap_element", canonicalName: "ios.double_tap", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Double taps an element identified in the current snapshot.",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The element ID from the snapshot.")
            ],
            output: "summary (typed text is never returned); a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "long_press_element", canonicalName: "ios.long_press", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Performs a long press gesture on an element for a specified duration in seconds.",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The element ID from the snapshot."),
                .init("durationSeconds", .number, required: false, "Duration in seconds (e.g. 0.85).")
            ],
            output: "summary (typed text is never returned); a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "swipe", canonicalName: "ios.swipe", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Swipes across an element or container in the specified direction (up, down, left, right).",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The element or container ID."),
                .init("direction", .string, required: true, "Direction: up, down, left, or right.", allowedValues: ["up", "down", "left", "right"])
            ],
            output: "summary (typed text is never returned); a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "drag_and_drop", canonicalName: "ios.drag", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Performs a press-and-drag gesture from a source element to a destination element (e.g., slide-to-buy slider or reordering items).",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("sourceElementID", .string, required: true, "The source element ID."),
                .init("destinationElementID", .string, required: true, "The destination element ID."),
                .init("holdDurationSeconds", .number, required: false, "Hold duration before dragging (default 0.1s).")
            ],
            output: "summary (typed text is never returned); a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "type_text", canonicalName: "ios.type_text", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Enters text into an editable text field identified in the current snapshot.",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The target text field element ID."),
                .init("text", .string, required: true, "The text to enter.")
            ],
            output: "summary (typed text is never returned); a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "navigate_back", canonicalName: "ios.back", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .implementedNotLiveVerified,
            summary: "Taps the back button of the navigation bar (a button inside the navigation bar, identified in the current snapshot).",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The navigation bar back button element ID.")
            ],
            output: "summary; a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "select_tab", canonicalName: "ios.select_tab", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Selects a tab bar item (a button inside the tab bar, identified in the current snapshot).",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The tab bar item element ID.")
            ],
            output: "summary; a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "dismiss_keyboard", canonicalName: "ios.dismiss_keyboard", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Dismisses the on-screen keyboard with the Return key of the focused text field.",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The focused text field element ID.")
            ],
            output: "summary; a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "clear_text", canonicalName: "ios.clear_text", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Clears text from an editable text field identified in the current snapshot.",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("elementID", .string, required: true, "The target element ID.")
            ],
            output: "summary (typed text is never returned); a fresh observation is required afterwards"
        ),
        ToolDescriptor(
            name: "scroll", canonicalName: "ios.scroll", version: 1, category: .interaction, platform: .ios, risk: .mutating, live: .liveVerified,
            summary: "Scrolls within a scrollable container in the specified direction.",
            input: [
                .init("snapshotID", .string, required: true, "The valid snapshot ID."),
                .init("containerID", .string, required: true, "The container element ID."),
                .init("direction", .string, required: true, "Scroll direction: up, down, left, or right.", allowedValues: ["up", "down", "left", "right"]),
                .init("velocity", .string, required: false, "Swipe speed policy: default or slow.", allowedValues: ["default", "slow"])
            ],
            output: "summary (typed text is never returned); a fresh observation is required afterwards"
        )
    ]

    private static let byName: [String: ToolDescriptor] = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, $0) })

    public static func descriptor(for toolName: String) -> ToolDescriptor? { byName[toolName] }

    public static var readOnlyTools: Set<String> { Set(descriptors.filter { $0.risk == .readOnly }.map(\.name)) }
    public static var mutatingTools: Set<String> { Set(descriptors.filter { $0.risk == .mutating }.map(\.name)) }

    public static func risk(of toolName: String) -> ToolRisk? { byName[toolName]?.risk }
}
