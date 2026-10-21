import Foundation

/// Decodes a schema-validated tool call into exactly one typed `IOSAction`. There is one small decoder per
/// tool; nothing below this point sees a dictionary of arguments. Messages match the previous validation.
struct IOSActionDecoder: Sendable {

    private struct Args {
        let tool: String
        let values: [String: AnyCodableValue]

        func nonEmpty(_ key: String, requirement: String) throws -> String {
            guard let v = values[key]?.stringValue, !v.isEmpty else { throw ToolRegistryError.invalidArguments("\(tool) requires \(requirement).") }
            return v
        }
        func number(_ key: String) -> Double? {
            if case .double(let d) = values[key] { return d }
            if case .int(let i) = values[key] { return Double(i) }
            return nil
        }
        func direction(_ key: String, requirement: String) throws -> ScrollDirection {
            guard let raw = values[key]?.stringValue?.lowercased(), let d = ScrollDirection(rawValue: raw) else {
                throw ToolRegistryError.invalidArguments("\(tool) requires \(requirement).")
            }
            return d
        }
        func target(_ noun: String = "'snapshotID' and 'elementID'") throws -> ElementTarget {
            ElementTarget(snapshotID: try nonEmpty("snapshotID", requirement: "non-empty \(noun)"), elementID: try nonEmpty("elementID", requirement: "non-empty \(noun)"))
        }
    }

    private static let decoders: [String: @Sendable (Args) throws -> IOSAction] = [
        "tap_element": { .tap(TapAction(target: try $0.target())) },
        "double_tap_element": { .doubleTap(DoubleTapAction(target: try $0.target())) },
        "long_press_element": { a in .longPress(LongPressAction(target: try a.target(), durationSeconds: a.number("durationSeconds") ?? 0.85)) },
        "swipe": { a in
            let req = "'snapshotID', 'elementID', and direction ('up', 'down', 'left', 'right')"
            return .swipe(SwipeAction(target: ElementTarget(snapshotID: try a.nonEmpty("snapshotID", requirement: req), elementID: try a.nonEmpty("elementID", requirement: req)),
                                      direction: try a.direction("direction", requirement: req)))
        },
        "scroll": { a in
            let req = "'snapshotID', 'containerID', and direction ('up', 'down', 'left', 'right')"
            var velocity = GestureVelocity.standard
            if let raw = a.values["velocity"]?.stringValue {
                guard let v = GestureVelocity(rawValue: raw) else { throw ToolRegistryError.invalidArguments("scroll velocity must be 'default' or 'slow'.") }
                velocity = v
            }
            return .scroll(ScrollAction(snapshotID: try a.nonEmpty("snapshotID", requirement: req), containerID: try a.nonEmpty("containerID", requirement: req),
                                        direction: try a.direction("direction", requirement: req), velocity: velocity))
        },
        "drag_and_drop": { a in
            let req = "'snapshotID', 'sourceElementID', and 'destinationElementID'"
            return .drag(DragAction(snapshotID: try a.nonEmpty("snapshotID", requirement: req), sourceElementID: try a.nonEmpty("sourceElementID", requirement: req),
                                    destinationElementID: try a.nonEmpty("destinationElementID", requirement: req), holdDurationSeconds: a.number("holdDurationSeconds") ?? 0.1))
        },
        "type_text": { a in
            let req = "'snapshotID', 'elementID', and 'text'"
            let target = ElementTarget(snapshotID: try a.nonEmpty("snapshotID", requirement: req), elementID: try a.nonEmpty("elementID", requirement: req))
            guard let text = a.values["text"]?.stringValue else { throw ToolRegistryError.invalidArguments("type_text requires \(req).") }
            guard text.count <= TypeTextAction.maxLength else {
                throw ToolRegistryError.invalidArguments("text length exceeds maximum permitted limit (\(TypeTextAction.maxLength) characters).")
            }
            return .typeText(TypeTextAction(target: target, text: text))
        },
        "clear_text": { .clearText(ClearTextAction(target: try $0.target())) },
        "navigate_back": { .back(BackAction(target: try $0.target())) },
        "select_tab": { .selectTab(SelectTabAction(target: try $0.target())) },
        "dismiss_keyboard": { .dismissKeyboard(DismissKeyboardAction(target: try $0.target())) },
        "wait_for_element": { a in
            let ident = try a.nonEmpty("identifier", requirement: "non-empty 'identifier'")
            let timeout = a.number("timeoutSeconds") ?? 5.0
            guard WaitForElementAction.timeoutRange.contains(timeout) else {
                throw ToolRegistryError.invalidArguments("timeoutSeconds must be between 0.1 and 60.0.")
            }
            return .waitForElement(WaitForElementAction(identifier: ident, timeoutSeconds: timeout))
        },
        "capture_screenshot": { .screenshot(ScreenshotAction(reason: $0.values["reason"]?.stringValue ?? "Inspection request")) },
        "get_element_details": { .elementDetails(ElementDetailsAction(target: try $0.target())) },
        "inspect_elements": { a in .inspectElements(InspectElementsAction(snapshotID: try a.nonEmpty("snapshotID", requirement: "non-empty 'snapshotID'"))) },
    ]

    /// Tools whose action needs the bundle ID rather than arguments.
    private static let bundleTools: [String: @Sendable (String) -> IOSAction] = [
        "get_accessibility_tree": { .accessibilityTree(AccessibilityTreeAction(bundleID: $0)) },
        "get_app_state": { .appState(AppStateAction(bundleID: $0)) },
    ]

    func decode(_ call: ToolCall, bundleID: String) throws -> IOSAction {
        if let make = Self.bundleTools[call.name] { return make(bundleID) }
        guard let decode = Self.decoders[call.name] else { throw ToolRegistryError.toolNotFound(call.name) }
        return try decode(Args(tool: call.name, values: call.arguments))
    }
}

/// Adapts a resolved tool call to the typed executor and back to a `ToolResult`. Holds no gesture logic.
struct IOSToolAdapter: Sendable {
    let executor: any IOSInteractionExecuting
    let logger: any AppLogger

    func execute(_ resolved: ToolResolver.Resolved, context: IOSActionContext) async throws -> ToolResult {
        let action = try IOSActionDecoder().decode(resolved.call, bundleID: context.bundleID)
        logger.debug(.validation, "ios.action.validated",
                     context: context.log.merged(with: LogContext(executionID: context.executionID, toolName: resolved.descriptor.name)),
                     fields: ["actionType": .string(action.actionType), "mutating": .bool(action.isMutating)])
        let exec = try await executor.execute(action, context: context)
        return ToolResult(callID: resolved.call.id, status: exec.output.status, summary: exec.output.summary,
                          observation: exec.output.observation, payload: exec.output.payload, artifacts: exec.result.evidence)
    }
}
