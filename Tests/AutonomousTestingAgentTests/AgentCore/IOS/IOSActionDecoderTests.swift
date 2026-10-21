import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("iOS action decoding")
struct IOSActionDecoderTests {
    private func decode(_ name: String, _ args: [String: AnyCodableValue]) throws -> IOSAction {
        try IOSActionDecoder().decode(ToolCall(id: "c", name: name, arguments: args), bundleID: "com.apple.mobilesafari")
    }
    private let base: [String: AnyCodableValue] = ["snapshotID": "s", "elementID": "e"]

    @Test func testEveryToolBackedActionDecodesToItsTypedValue() throws {
        let t = ElementTarget(snapshotID: "s", elementID: "e")
        #expect(try decode("tap_element", base) == .tap(TapAction(target: t)))
        #expect(try decode("double_tap_element", base) == .doubleTap(DoubleTapAction(target: t)))
        #expect(try decode("long_press_element", base.merging(["durationSeconds": 2]) { $1 }) == .longPress(LongPressAction(target: t, durationSeconds: 2)))
        #expect(try decode("long_press_element", base) == .longPress(LongPressAction(target: t)))
        #expect(try decode("swipe", base.merging(["direction": "LEFT"]) { $1 }) == .swipe(SwipeAction(target: t, direction: .left)))
        #expect(try decode("scroll", ["snapshotID": "s", "containerID": "c", "direction": "down"]) == .scroll(ScrollAction(snapshotID: "s", containerID: "c", direction: .down)))
        #expect(try decode("drag_and_drop", ["snapshotID": "s", "sourceElementID": "a", "destinationElementID": "b", "holdDurationSeconds": 0.3])
                == .drag(DragAction(snapshotID: "s", sourceElementID: "a", destinationElementID: "b", holdDurationSeconds: 0.3)))
        #expect(try decode("type_text", base.merging(["text": "hi"]) { $1 }) == .typeText(TypeTextAction(target: t, text: "hi")))
        #expect(try decode("clear_text", base) == .clearText(ClearTextAction(target: t)))
        #expect(try decode("wait_for_element", ["identifier": "id", "timeoutSeconds": 3]) == .waitForElement(WaitForElementAction(identifier: "id", timeoutSeconds: 3)))
        #expect(try decode("capture_screenshot", [:]) == .screenshot(ScreenshotAction(reason: "Inspection request")))
        #expect(try decode("get_element_details", base) == .elementDetails(ElementDetailsAction(target: t)))
        #expect(try decode("inspect_elements", ["snapshotID": "s"]) == .inspectElements(InspectElementsAction(snapshotID: "s")))
        #expect(try decode("get_accessibility_tree", [:]) == .accessibilityTree(AccessibilityTreeAction(bundleID: "com.apple.mobilesafari")))
        #expect(try decode("get_app_state", [:]) == .appState(AppStateAction(bundleID: "com.apple.mobilesafari")))
    }

    @Test func testEveryCatalogedIOSToolIsDecodable() throws {
        for d in ToolCatalog.descriptors where d.platform == .ios {
            var args: [String: AnyCodableValue] = [:]
            for f in d.input where f.required {
                args[f.name] = f.allowedValues?.first.map { AnyCodableValue.string($0) } ?? (f.type == .string ? "x" : (f.type == .number ? 1 : .bool(true)))
            }
            let action = try decode(d.name, args)
            #expect(action.isMutating == (d.risk == .mutating), "\(d.name)")
        }
    }

    @Test func testMissingEmptyAndOutOfRangeInputIsRejectedWithTheSameMessages() {
        #expect(throws: ToolRegistryError.invalidArguments("tap_element requires non-empty 'snapshotID' and 'elementID'.")) { _ = try decode("tap_element", ["snapshotID": "s", "elementID": ""]) }
        #expect(throws: ToolRegistryError.invalidArguments("swipe requires 'snapshotID', 'elementID', and direction ('up', 'down', 'left', 'right').")) { _ = try decode("swipe", base) }
        #expect(throws: ToolRegistryError.invalidArguments("timeoutSeconds must be between 0.1 and 60.0.")) { _ = try decode("wait_for_element", ["identifier": "i", "timeoutSeconds": 61]) }
        #expect(throws: ToolRegistryError.invalidArguments("text length exceeds maximum permitted limit (500 characters).")) {
            _ = try decode("type_text", base.merging(["text": .string(String(repeating: "a", count: 501))]) { $1 })
        }
        #expect(throws: ToolRegistryError.invalidArguments("wait_for_element requires non-empty 'identifier'.")) { _ = try decode("wait_for_element", ["identifier": ""]) }
    }

    @Test func testUnknownToolsAndHostToolsAreNotIOSActions() {
        #expect(throws: ToolRegistryError.toolNotFound("delete_all")) { _ = try decode("delete_all", [:]) }
        #expect(throws: ToolRegistryError.toolNotFound("get_project_info")) { _ = try decode("get_project_info", [:]) }
    }
}
