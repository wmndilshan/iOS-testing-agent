import Foundation

/// A reference to a UI element as *proposed* by a model or a scenario: the snapshot it was seen in and its id.
///
/// This is a model-suggested target, never a trusted one. Trust comes from resolving it against the current
/// observation (`TrustedActionValidator`, then the driver's own snapshot check at execution), which also
/// supplies role, identifier, label and frame. Coordinates and frames are never accepted from a model.
public struct ElementTarget: Sendable, Equatable {
    public let snapshotID: String
    public let elementID: String

    public init(snapshotID: String, elementID: String) {
        self.snapshotID = snapshotID
        self.elementID = elementID
    }
}

public struct TapAction: Sendable, Equatable { public let target: ElementTarget; public init(target: ElementTarget) { self.target = target } }
public struct DoubleTapAction: Sendable, Equatable { public let target: ElementTarget; public init(target: ElementTarget) { self.target = target } }

public struct LongPressAction: Sendable, Equatable {
    public let target: ElementTarget
    public let durationSeconds: Double
    public init(target: ElementTarget, durationSeconds: Double = 0.85) { self.target = target; self.durationSeconds = durationSeconds }
}

/// A single swipe gesture across an element. Duration/velocity are deliberately absent: the driver API does not
/// expose them, and parameters are not invented.
public struct SwipeAction: Sendable, Equatable {
    public let target: ElementTarget
    public let direction: ScrollDirection
    public init(target: ElementTarget, direction: ScrollDirection) { self.target = target; self.direction = direction }
}

/// The speed policy of a swipe-driven gesture: the SDK's default or `XCUIGestureVelocitySlow`. Trusted scenario data only.
public enum GestureVelocity: String, Sendable, Equatable, CaseIterable {
    case standard = "default"
    case slow
}

/// One directional scroll of a container. "Scroll until visible" is a different, bounded capability (not implemented).
public struct ScrollAction: Sendable, Equatable {
    public let snapshotID: String
    public let containerID: String
    public let direction: ScrollDirection
    public let velocity: GestureVelocity
    public init(snapshotID: String, containerID: String, direction: ScrollDirection, velocity: GestureVelocity = .standard) {
        self.snapshotID = snapshotID; self.containerID = containerID; self.direction = direction; self.velocity = velocity
    }
}

public struct DragAction: Sendable, Equatable {
    public let snapshotID: String
    public let sourceElementID: String
    public let destinationElementID: String
    public let holdDurationSeconds: Double
    public init(snapshotID: String, sourceElementID: String, destinationElementID: String, holdDurationSeconds: Double = 0.1) {
        self.snapshotID = snapshotID; self.sourceElementID = sourceElementID
        self.destinationElementID = destinationElementID; self.holdDurationSeconds = holdDurationSeconds
    }
}

/// Text entry. The text is sensitive by default: it never appears in `description`, logs or results.
public struct TypeTextAction: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maxLength = 500
    public let target: ElementTarget
    public let text: String
    public init(target: ElementTarget, text: String) { self.target = target; self.text = text }
    public var description: String { "TypeTextAction(target: \(target.elementID), text: <\(text.count) chars redacted>)" }
    public var debugDescription: String { description }
}

public struct ClearTextAction: Sendable, Equatable { public let target: ElementTarget; public init(target: ElementTarget) { self.target = target } }

/// Waits (bounded) for an element to appear in fresh observations. Polling is bounded by `timeoutSeconds`.
public struct WaitForElementAction: Sendable, Equatable {
    public static let timeoutRange: ClosedRange<Double> = 0.1...60.0
    public let identifier: String
    public let timeoutSeconds: Double
    public let pollIntervalSeconds: Double
    public init(identifier: String, timeoutSeconds: Double = 5.0, pollIntervalSeconds: Double = 0.5) {
        self.identifier = identifier; self.timeoutSeconds = timeoutSeconds; self.pollIntervalSeconds = pollIntervalSeconds
    }
}

public struct ScreenshotAction: Sendable, Equatable { public let reason: String; public init(reason: String) { self.reason = reason } }
public struct AccessibilityTreeAction: Sendable, Equatable { public let bundleID: String; public init(bundleID: String) { self.bundleID = bundleID } }
public struct AppStateAction: Sendable, Equatable { public let bundleID: String; public init(bundleID: String) { self.bundleID = bundleID } }
public struct ElementDetailsAction: Sendable, Equatable { public let target: ElementTarget; public init(target: ElementTarget) { self.target = target } }
public struct InspectElementsAction: Sendable, Equatable { public let snapshotID: String; public init(snapshotID: String) { self.snapshotID = snapshotID } }

// MARK: - Modeled but not implemented

// These are typed so future tools can be added without redesign. None has a tool descriptor or an
// implementation; executing one fails closed with `unsupportedCapability`.

public enum KeyboardKey: String, Sendable, Equatable, CaseIterable { case returnKey = "return", delete, escape, tab }
public struct KeyPressAction: Sendable, Equatable { public let key: KeyboardKey; public init(key: KeyboardKey) { self.key = key } }
/// Dismisses the keyboard with the Return key of the focused text field (`target`). No coordinates, no global gesture.
public struct DismissKeyboardAction: Sendable, Equatable { public let target: ElementTarget; public init(target: ElementTarget) { self.target = target } }
public struct DismissOverlayAction: Sendable, Equatable { public let target: ElementTarget; public init(target: ElementTarget) { self.target = target } }
public struct BackAction: Sendable, Equatable { public let target: ElementTarget; public init(target: ElementTarget) { self.target = target } }
public struct SelectTabAction: Sendable, Equatable { public let target: ElementTarget; public init(target: ElementTarget) { self.target = target } }
public struct SelectPickerValueAction: Sendable, Equatable {
    public let target: ElementTarget
    public let value: String
    public init(target: ElementTarget, value: String) { self.target = target; self.value = value }
}
public struct LaunchAppAction: Sendable, Equatable { public let bundleID: String; public init(bundleID: String) { self.bundleID = bundleID } }
public struct TerminateAppAction: Sendable, Equatable { public let bundleID: String; public init(bundleID: String) { self.bundleID = bundleID } }
public struct ActivateAppAction: Sendable, Equatable { public let bundleID: String; public init(bundleID: String) { self.bundleID = bundleID } }

/// The closed set of iOS interactions. A tool call is decoded into exactly one of these typed values; there is
/// no dictionary-shaped action anywhere below the tool boundary.
public enum IOSAction: Sendable, Equatable {
    case tap(TapAction), doubleTap(DoubleTapAction), longPress(LongPressAction)
    case swipe(SwipeAction), scroll(ScrollAction), drag(DragAction)
    case typeText(TypeTextAction), clearText(ClearTextAction)
    case waitForElement(WaitForElementAction)
    case screenshot(ScreenshotAction), accessibilityTree(AccessibilityTreeAction), appState(AppStateAction)
    case elementDetails(ElementDetailsAction), inspectElements(InspectElementsAction)
    // Modeled, not implemented (fail closed):
    case keyPress(KeyPressAction), dismissKeyboard(DismissKeyboardAction), dismissOverlay(DismissOverlayAction)
    case back(BackAction), selectTab(SelectTabAction), selectPickerValue(SelectPickerValueAction)
    case launchApp(LaunchAppAction), terminateApp(TerminateAppAction), activateApp(ActivateAppAction)

    /// Stable, secret-free name used in logs and results.
    public var actionType: String {
        switch self {
        case .tap: return "tap"
        case .doubleTap: return "double_tap"
        case .longPress: return "long_press"
        case .swipe: return "swipe"
        case .scroll: return "scroll"
        case .drag: return "drag"
        case .typeText: return "type_text"
        case .clearText: return "clear_text"
        case .waitForElement: return "wait_for_element"
        case .screenshot: return "screenshot"
        case .accessibilityTree: return "accessibility_tree"
        case .appState: return "app_state"
        case .elementDetails: return "element_details"
        case .inspectElements: return "inspect_elements"
        case .keyPress: return "key_press"
        case .dismissKeyboard: return "dismiss_keyboard"
        case .dismissOverlay: return "dismiss_overlay"
        case .back: return "back"
        case .selectTab: return "select_tab"
        case .selectPickerValue: return "select_picker_value"
        case .launchApp: return "launch_app"
        case .terminateApp: return "terminate_app"
        case .activateApp: return "activate_app"
        }
    }

    /// Whether the action can change the app or simulator. Trusted classification lives in `ToolCatalog`;
    /// this is only used to keep the typed model and the catalog consistent (tested).
    public var isMutating: Bool {
        switch self {
        case .tap, .doubleTap, .longPress, .swipe, .scroll, .drag, .typeText, .clearText,
             .keyPress, .dismissKeyboard, .dismissOverlay, .back, .selectTab, .selectPickerValue,
             .launchApp, .terminateApp, .activateApp:
            return true
        case .waitForElement, .screenshot, .accessibilityTree, .appState, .elementDetails, .inspectElements:
            return false
        }
    }
}
