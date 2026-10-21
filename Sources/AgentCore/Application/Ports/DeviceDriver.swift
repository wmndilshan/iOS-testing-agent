import Foundation

public protocol DeviceDriver: Sendable {
    /// Captures a fresh, sanitized accessibility observation of the running application.
    func captureObservation(bundleID: String) async throws -> Observation

    /// Performs a tap on a specific element identified in a valid snapshot (using hittable or center coordinate fallback).
    func tap(snapshotID: String, elementID: String) async throws -> ToolResult

    /// Performs a double tap on an element.
    func doubleTap(snapshotID: String, elementID: String) async throws -> ToolResult

    /// Performs a long press on an element for a given duration.
    func longPress(snapshotID: String, elementID: String, durationSeconds: Double) async throws -> ToolResult

    /// Swipes across an element in the specified direction.
    func swipe(snapshotID: String, elementID: String, direction: ScrollDirection) async throws -> ToolResult

    /// Drags from a source element to a destination element (such as order sliders or list items).
    func dragAndDrop(snapshotID: String, sourceElementID: String, destinationElementID: String, holdDurationSeconds: Double) async throws -> ToolResult

    /// Enters text into an editable element identified in a valid snapshot.
    func typeText(snapshotID: String, elementID: String, text: String) async throws -> ToolResult

    /// Clears text from an editable element.
    func clearText(snapshotID: String, elementID: String) async throws -> ToolResult

    /// Scrolls within a container element.
    func scroll(snapshotID: String, containerID: String, direction: ScrollDirection) async throws -> ToolResult

    /// Scrolls with an explicit swipe speed policy. Drivers that cannot honor a non-default policy refuse (fail closed).
    func scroll(snapshotID: String, containerID: String, direction: ScrollDirection, velocity: GestureVelocity) async throws -> ToolResult


    /// Taps the back button inside the navigation bar (resolved within the bar, never by coordinates).
    func navigateBack(snapshotID: String, elementID: String) async throws -> ToolResult

    /// Selects a tab bar item (resolved within the tab bar).
    func selectTab(snapshotID: String, elementID: String) async throws -> ToolResult

    /// Dismisses the keyboard with the Return key of the focused text field.
    func dismissKeyboard(snapshotID: String, elementID: String) async throws -> ToolResult

    /// Retrieves detailed metadata about an element.
    func getElementDetails(snapshotID: String, elementID: String) async throws -> ToolResult

    /// Captures visual screenshot evidence fallback.
    func captureScreenshot(reason: String) async throws -> (imagePath: String, observation: Observation?)

    /// Read-only inspection asserting presence, identity, and bounds of expected elements without mutation.
    func inspectElements(snapshotID: String, expectedElements: [ScenarioExpectedElement]) async throws -> ToolResult
}

extension DeviceDriver {
    /// Default: only the SDK's default speed is supported; a requested slow swipe is refused rather than silently ignored.
    public func scroll(snapshotID: String, containerID: String, direction: ScrollDirection, velocity: GestureVelocity) async throws -> ToolResult {
        guard velocity == .standard else { throw DriverError.unsupportedCapability("velocity-controlled scroll is not implemented by this driver") }
        return try await scroll(snapshotID: snapshotID, containerID: containerID, direction: direction)
    }
}

extension DeviceDriver {
    /// Drivers without these capabilities refuse (fail closed); nothing is reported as done.
    public func navigateBack(snapshotID: String, elementID: String) async throws -> ToolResult { throw DriverError.unsupportedCapability("navigate_back is not implemented by this driver") }
    public func selectTab(snapshotID: String, elementID: String) async throws -> ToolResult { throw DriverError.unsupportedCapability("select_tab is not implemented by this driver") }
    public func dismissKeyboard(snapshotID: String, elementID: String) async throws -> ToolResult { throw DriverError.unsupportedCapability("dismiss_keyboard is not implemented by this driver") }
}
