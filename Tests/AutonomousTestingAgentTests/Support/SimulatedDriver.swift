import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

public actor SimulatedDriver: DeviceDriver {
    public static let screenshotPath = FileManager.default.temporaryDirectory.appendingPathComponent("mock_screenshot.png").path

    public var currentSnapshot: Observation
    public var storedLocators: [String: ElementLocator] = [:]
    public var capturedActions: [String] = []
    public var invokedActionCount: [String: Int] = [:]
    public var shouldThrowError: DriverError?
    public var queuedSnapshots: [Observation] = []
    /// Makes exactly the next `captureObservation` throw, then clears itself (a failing post-action observation).

    public init(currentSnapshot: Observation? = nil) {
        let snapshot: Observation
        if let s = currentSnapshot {
            snapshot = s
        } else {
            snapshot = Observation(
                snapshotID: "snap_mock_1",
                bundleID: SimulatorTargetConfiguration.current.bundleID,
                appState: .runningForeground,
                source: .accessibilityTree,
                elements: [
                    UIElementSnapshot(id: "elem_1", role: "textField", label: "Username", identifier: "username_field"),
                    UIElementSnapshot(id: "elem_2", role: "secureTextField", label: "Password", identifier: "password_field", isSecure: true),
                    UIElementSnapshot(id: "elem_3", role: "button", label: "Log In", identifier: "login_button"),
                    UIElementSnapshot(id: "elem_slider", role: "slider", label: "Slide to Buy", identifier: "slide_to_buy")
                ]
            )
        }
        self.currentSnapshot = snapshot
        for el in snapshot.elements {
            self.storedLocators[el.id] = ElementLocator(
                snapshotID: snapshot.snapshotID,
                elementID: el.id,
                role: el.role,
                identifier: el.identifier,
                label: el.label,
                placeholderValue: el.placeholderValue,
                depth: el.depth,
                parentID: el.parentID,
                frame: el.frame
            )
        }
    }

    public func setSnapshot(_ observation: Observation) {
        self.currentSnapshot = observation
        self.storedLocators.removeAll()
        for el in observation.elements {
            self.storedLocators[el.id] = ElementLocator(
                snapshotID: observation.snapshotID,
                elementID: el.id,
                role: el.role,
                identifier: el.identifier,
                label: el.label,
                placeholderValue: el.placeholderValue,
                depth: el.depth,
                parentID: el.parentID,
                frame: el.frame
            )
        }
    }

    public func setLocator(_ locator: ElementLocator) {
        self.storedLocators[locator.elementID] = locator
    }

    public func getLocator(elementID: String) -> ElementLocator? {
        return storedLocators[elementID]
    }

    public func setShouldThrowError(_ error: DriverError?) {
        self.shouldThrowError = error
    }

    public func queueNextSnapshot(_ observation: Observation) {
        self.queuedSnapshots.append(observation)
    }

    public func captureObservation(bundleID: String) async throws -> Observation {
        if let err = shouldThrowError { throw err }
        capturedActions.append("captureObservation(\(bundleID))")
        invokedActionCount["captureObservation", default: 0] += 1
        if !queuedSnapshots.isEmpty {
            let next = queuedSnapshots.removeFirst()
            setSnapshot(next)
        }
        return currentSnapshot
    }

    public func tap(snapshotID: String, elementID: String) async throws -> ToolResult {
        invokedActionCount["tap", default: 0] += 1
        capturedActions.append("tap(\(elementID))")
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        guard let locator = storedLocators[elementID] else {
            throw DriverError.elementNotFound(elementID)
        }
        guard let el = currentSnapshot.elements.first(where: { $0.id == elementID }) else {
            throw DriverError.elementNotFound(elementID)
        }
        // Strict element type check (prevent text heading from being reinterpreted as button)
        guard el.role == locator.role else {
            throw DriverError.typeMismatch(expected: locator.role, actual: el.role, elementID: elementID)
        }

        // Ambiguity check for duplicate labels sharing the same role without unique identifier
        if let label = locator.label, !label.isEmpty {
            let matches = currentSnapshot.elements.filter { $0.role == locator.role && $0.label == label }
            if matches.count > 1 && (locator.identifier == nil || locator.identifier?.isEmpty == true) {
                let candidates = matches.map { ElementCandidateSummary(elementID: $0.id, role: $0.role, identifier: $0.identifier, label: $0.label, frame: $0.frame) }
                throw DriverError.ambiguousElement(label, count: matches.count, candidates: candidates)
            }
        }

        guard el.isEnabled else {
            throw DriverError.elementDisabled(elementID)
        }
        guard el.isHittable else {
            throw DriverError.elementNotHittable(elementID)
        }

        if queuedSnapshots.isEmpty {
            if el.identifier == "change-language-dropdown-button" || el.id == "elem_29" || el.label == "English" {
                let modalSnapshot = Observation(
                    snapshotID: "snap_modal_\(UUID().uuidString.prefix(6))",
                    bundleID: currentSnapshot.bundleID,
                    appState: .runningForeground,
                    source: .accessibilityTree,
                    elements: [
                        UIElementSnapshot(id: "elem_window", role: "window", label: "Main Window", identifier: "main_window", depth: 0),
                        UIElementSnapshot(id: "elem_modal_title", parentID: "elem_window", role: "staticText", label: "Language", identifier: "Language", depth: 1),
                        UIElementSnapshot(id: "elem_modal_close", parentID: "elem_window", role: "button", label: "close_var_1", identifier: "close_var_1", isEnabled: true, isHittable: true, depth: 1, frame: ElementFrame(x: 350, y: 440, width: 30, height: 30)),
                        UIElementSnapshot(id: "elem_lang_en", parentID: "elem_window", role: "button", label: "English", identifier: "English", isEnabled: true, isHittable: true, depth: 1)
                    ]
                )
                setSnapshot(modalSnapshot)
            } else if el.identifier == "close_var_1" || el.id == "elem_33" || el.label == "close_var_1" {
                let baselineSnapshot = Observation(
                    snapshotID: "snap_baseline_\(UUID().uuidString.prefix(6))",
                    bundleID: currentSnapshot.bundleID,
                    appState: .runningForeground,
                    source: .accessibilityTree,
                    elements: [
                        UIElementSnapshot(id: "elem_lang_btn", role: "button", label: "English", identifier: "change-language-dropdown-button", isEnabled: true, isHittable: true)
                    ]
                )
                setSnapshot(baselineSnapshot)
            }
        }

        return ToolResult(
            callID: UUID().uuidString,
            status: .success,
            summary: "Tapped element '\(elementID)' (\(el.label ?? el.role)).",
            observation: currentSnapshot
        )
    }

    public func doubleTap(snapshotID: String, elementID: String) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        guard currentSnapshot.elements.contains(where: { $0.id == elementID }) else {
            throw DriverError.elementNotFound(elementID)
        }
        capturedActions.append("doubleTap(\(elementID))")
        invokedActionCount["doubleTap", default: 0] += 1
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "Double tapped '\(elementID)'.")
    }

    public func longPress(snapshotID: String, elementID: String, durationSeconds: Double) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        guard currentSnapshot.elements.contains(where: { $0.id == elementID }) else {
            throw DriverError.elementNotFound(elementID)
        }
        capturedActions.append("longPress(\(elementID), \(durationSeconds)s)")
        invokedActionCount["longPress", default: 0] += 1
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "Long pressed '\(elementID)' for \(durationSeconds)s.")
    }

    public func swipe(snapshotID: String, elementID: String, direction: ScrollDirection) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        guard currentSnapshot.elements.contains(where: { $0.id == elementID }) else {
            throw DriverError.elementNotFound(elementID)
        }
        capturedActions.append("swipe(\(elementID), \(direction.rawValue))")
        invokedActionCount["swipe", default: 0] += 1
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "Swiped \(direction.rawValue) across '\(elementID)'.")
    }

    public func dragAndDrop(
        snapshotID: String,
        sourceElementID: String,
        destinationElementID: String,
        holdDurationSeconds: Double
    ) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        capturedActions.append("dragAndDrop(\(sourceElementID) -> \(destinationElementID))")
        invokedActionCount["dragAndDrop", default: 0] += 1
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "Dragged '\(sourceElementID)' to '\(destinationElementID)'.")
    }

    public func typeText(snapshotID: String, elementID: String, text: String) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        guard let el = currentSnapshot.elements.first(where: { $0.id == elementID }) else {
            throw DriverError.elementNotFound(elementID)
        }

        capturedActions.append("typeText(\(elementID), textLen=\(text.count))")
        invokedActionCount["typeText", default: 0] += 1
        return ToolResult(
            callID: UUID().uuidString,
            status: .success,
            summary: "Typed text into '\(elementID)' (\(el.label ?? el.role)).",
            observation: currentSnapshot
        )
    }

    public func clearText(snapshotID: String, elementID: String) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        capturedActions.append("clearText(\(elementID))")
        invokedActionCount["clearText", default: 0] += 1
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "Cleared text in '\(elementID)'.")
    }

    public func scroll(snapshotID: String, containerID: String, direction: ScrollDirection, velocity: GestureVelocity) async throws -> ToolResult {
        let result = try await scroll(snapshotID: snapshotID, containerID: containerID, direction: direction)
        if velocity != .standard { capturedActions.append("scroll-velocity(\(velocity.rawValue))") }
        return result
    }

    public func scroll(snapshotID: String, containerID: String, direction: ScrollDirection) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        capturedActions.append("scroll(\(containerID), \(direction.rawValue))")
        invokedActionCount["scroll", default: 0] += 1
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "Scrolled \(direction.rawValue) on '\(containerID)'.")
    }

    public func navigateBack(snapshotID: String, elementID: String) async throws -> ToolResult { try mockBar("navigateBack", snapshotID, elementID) }
    public func selectTab(snapshotID: String, elementID: String) async throws -> ToolResult { try mockBar("selectTab", snapshotID, elementID) }
    public func dismissKeyboard(snapshotID: String, elementID: String) async throws -> ToolResult { try mockBar("dismissKeyboard", snapshotID, elementID) }

    private func mockBar(_ name: String, _ snapshotID: String, _ elementID: String) throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else { throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID) }
        guard currentSnapshot.elements.contains(where: { $0.id == elementID }) else { throw DriverError.elementNotFound(elementID) }
        capturedActions.append("\(name)(\(elementID))")
        invokedActionCount[name, default: 0] += 1
        return ToolResult(callID: UUID().uuidString, status: .success, summary: "\(name) on '\(elementID)'.")
    }

    public func getElementDetails(snapshotID: String, elementID: String) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        // Same binding as the live driver and as every other snapshot-taking method here: the details come from the
        // snapshot the call was authorized against, never from whatever this driver holds now.
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }
        guard let el = currentSnapshot.elements.first(where: { $0.id == elementID }) else {
            throw DriverError.elementNotFound(elementID)
        }
        invokedActionCount["getElementDetails", default: 0] += 1
        return ToolResult(
            callID: UUID().uuidString,
            status: .success,
            summary: "Details for '\(elementID)': role=\(el.role), label=\(el.label ?? "none"), id=\(el.identifier ?? "none")"
        )
    }

    public func captureScreenshot(reason: String) async throws -> (imagePath: String, observation: Observation?) {
        if let err = shouldThrowError { throw err }
        capturedActions.append("captureScreenshot(\(reason))")
        invokedActionCount["captureScreenshot", default: 0] += 1
        return (Self.screenshotPath, currentSnapshot)
    }

    public func inspectElements(
        snapshotID: String,
        expectedElements: [ScenarioExpectedElement]
    ) async throws -> ToolResult {
        if let err = shouldThrowError { throw err }
        guard snapshotID == currentSnapshot.snapshotID else {
            throw DriverError.staleSnapshot(requested: snapshotID, current: currentSnapshot.snapshotID)
        }

        capturedActions.append("inspectElements(\(expectedElements.count))")
        invokedActionCount["inspectElements", default: 0] += 1

        var failureDetails: [String] = []
        for exp in expectedElements {
            if let matched = currentSnapshot.elements.first(where: { exp.matches(element: $0) }) {
                let (valid, reason) = exp.validate(against: matched)
                if !valid {
                    failureDetails.append("\(exp.role) (\(exp.identifier ?? exp.label ?? "unnamed")): \(reason)")
                }
            } else {
                failureDetails.append("\(exp.role) (\(exp.identifier ?? exp.label ?? exp.role)): Missing from hierarchy")
            }
        }

        if !failureDetails.isEmpty {
            throw DriverError.actionFailed("Inspection assertions failed: \(failureDetails.joined(separator: "; "))")
        }

        return ToolResult(
            callID: UUID().uuidString,
            status: .success,
            summary: "Mock inspection verified \(expectedElements.count) expected elements.",
            observation: currentSnapshot
        )
    }
}

/// What a simulated driver remembers about each element of a snapshot (test support only).
public struct ElementLocator: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let elementID: String
    public let role: String
    public let identifier: String?
    public let label: String?
    public let placeholderValue: String?
    public let depth: Int
    public let parentID: String?
    public let frame: ElementFrame?

    public init(
        snapshotID: String,
        elementID: String,
        role: String,
        identifier: String? = nil,
        label: String? = nil,
        placeholderValue: String? = nil,
        depth: Int = 0,
        parentID: String? = nil,
        frame: ElementFrame? = nil
    ) {
        self.snapshotID = snapshotID
        self.elementID = elementID
        self.role = role
        self.identifier = identifier
        self.label = label
        self.placeholderValue = placeholderValue
        self.depth = depth
        self.parentID = parentID
        self.frame = frame
    }
}
