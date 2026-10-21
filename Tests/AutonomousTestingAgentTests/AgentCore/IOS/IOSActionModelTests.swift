import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Typed iOS actions")
struct IOSActionModelTests {
    private let t = ElementTarget(snapshotID: "s", elementID: "e")

    private func allActions() -> [IOSAction] {
        [.tap(TapAction(target: t)), .doubleTap(DoubleTapAction(target: t)), .longPress(LongPressAction(target: t)),
         .swipe(SwipeAction(target: t, direction: .up)), .scroll(ScrollAction(snapshotID: "s", containerID: "c", direction: .down)),
         .drag(DragAction(snapshotID: "s", sourceElementID: "a", destinationElementID: "b")),
         .typeText(TypeTextAction(target: t, text: "x")), .clearText(ClearTextAction(target: t)),
         .waitForElement(WaitForElementAction(identifier: "i")), .screenshot(ScreenshotAction(reason: "r")),
         .accessibilityTree(AccessibilityTreeAction(bundleID: "b")), .appState(AppStateAction(bundleID: "b")),
         .elementDetails(ElementDetailsAction(target: t)), .inspectElements(InspectElementsAction(snapshotID: "s")),
         .keyPress(KeyPressAction(key: .returnKey)), .dismissKeyboard(DismissKeyboardAction(target: t)), .dismissOverlay(DismissOverlayAction(target: t)),
         .back(BackAction(target: t)), .selectTab(SelectTabAction(target: t)), .selectPickerValue(SelectPickerValueAction(target: t, value: "v")),
         .launchApp(LaunchAppAction(bundleID: "b")), .terminateApp(TerminateAppAction(bundleID: "b")), .activateApp(ActivateAppAction(bundleID: "b"))]
    }

    @Test func testEveryActionHasAUniqueStableTypeName() {
        let types = allActions().map(\.actionType)
        #expect(types.count == 23 && Set(types).count == 23)
        #expect(types.allSatisfy { $0.range(of: #"^[a-z_]+$"#, options: .regularExpression) != nil })
    }

    @Test func testTypedTextIsNeverRenderedInDescriptions() {
        let action = TypeTextAction(target: t, text: "SUPER-SECRET-PASSWORD")
        #expect(!action.description.contains("SUPER-SECRET") && !action.debugDescription.contains("SUPER-SECRET"))
        #expect(action.description.contains("21 chars redacted"))
    }

    @Test func testMutabilityMatchesTheTrustedCatalogForEveryToolBackedAction() {
        let toolForType: [String: String] = [
            "tap": "tap_element", "double_tap": "double_tap_element", "long_press": "long_press_element", "swipe": "swipe",
            "scroll": "scroll", "drag": "drag_and_drop", "type_text": "type_text", "clear_text": "clear_text",
            "wait_for_element": "wait_for_element", "screenshot": "capture_screenshot", "accessibility_tree": "get_accessibility_tree",
            "app_state": "get_app_state", "element_details": "get_element_details", "inspect_elements": "inspect_elements",
        ]
        for action in allActions() {
            guard let tool = toolForType[action.actionType] else { continue }
            let risk = ToolCatalog.risk(of: tool)
            #expect(action.isMutating == (risk == .mutating), "\(action.actionType) vs catalog '\(tool)'")
        }
        #expect(toolForType.count == 14)
    }

    @Test func testModeledButUnimplementedActionsAreAllMutating() {
        for action in allActions() where ["key_press", "dismiss_keyboard", "dismiss_overlay", "back", "select_tab", "select_picker_value", "launch_app", "terminate_app", "activate_app"].contains(action.actionType) {
            #expect(action.isMutating, "\(action.actionType)")
        }
    }

    @Test func testActionsCarryOnlyTypedFieldsNeverFramesOrDictionaries() {
        // A model can suggest a target id; there is no field that accepts coordinates, frames or free-form arguments.
        let mirrorLabels = allActions().flatMap { action -> [String] in
            Mirror(reflecting: action).children.flatMap { child in Mirror(reflecting: child.value).children.map { $0.label ?? "" } }
        }
        for forbidden in ["frame", "x", "y", "coordinate", "arguments", "params"] { #expect(!mirrorLabels.contains(forbidden), "\(forbidden)") }
    }

    @Test func testWaitAndLongPressDefaultsAreExplicit() {
        #expect(WaitForElementAction(identifier: "i").timeoutSeconds == 5.0 && WaitForElementAction(identifier: "i").pollIntervalSeconds == 0.5)
        #expect(LongPressAction(target: t).durationSeconds == 0.85 && DragAction(snapshotID: "s", sourceElementID: "a", destinationElementID: "b").holdDurationSeconds == 0.1)
        #expect(WaitForElementAction.timeoutRange == 0.1...60.0 && TypeTextAction.maxLength == 500)
    }
}
