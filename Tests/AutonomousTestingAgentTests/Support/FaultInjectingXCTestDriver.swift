import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Fault-injection matrix: a test-only `DeviceDriver` implementation that counts every call (split into
/// observation calls vs. mutating tool calls, by name) and can be configured to throw a specific
/// `DriverError` or hand back a specific/malformed `Observation` on demand.
///
/// This sits entirely BELOW the trust boundary: it stands in for the real device/XCTest layer that
/// `ToolRegistry`/`ScenarioStepDispatcher`/`DispatchAuthorizer`/`ProposalAdmission`/
/// `ScenarioExecutionController` already depend on through `DeviceDriver` — exactly like
/// `SimulatedDriver` does today, never a new call site into any of those trusted types, and never a
/// production `if faultInjected { ... }` branch anywhere in `Sources/`. A driver invocation count of zero
/// is a reliable proxy for "no real device action was ever attempted": every one of `ToolRegistry`'s
/// mutating tool implementations bottoms out in exactly one call to this protocol.
final actor FaultInjectingXCTestDriver: DeviceDriver {
    private let inner: SimulatedDriver

    private(set) var observationCallCount = 0
    private(set) var mutationCallCount = 0
    private(set) var mutationCallsByName: [String: Int] = [:]

    private var observationQueue: [Observation] = []
    private var observationErrorOnNextCall: DriverError?
    private var mutationErrorAlways: DriverError?
    private var mutationErrorOnNextCall: DriverError?

    init(inner: SimulatedDriver) { self.inner = inner }

    // MARK: - Injection configuration

    func queueObservations(_ obs: [Observation]) { observationQueue.append(contentsOf: obs) }
    func failNextObservation(_ error: DriverError) { observationErrorOnNextCall = error }
    func failAllMutations(_ error: DriverError) { mutationErrorAlways = error }
    func failNextMutation(_ error: DriverError) { mutationErrorOnNextCall = error }

    // MARK: - DeviceDriver

    func captureObservation(bundleID: String) async throws -> Observation {
        observationCallCount += 1
        if let err = observationErrorOnNextCall { observationErrorOnNextCall = nil; throw err }
        if !observationQueue.isEmpty {
            let obs = observationQueue.removeFirst()
            await inner.setSnapshot(obs)
            return obs
        }
        return try await inner.captureObservation(bundleID: bundleID)
    }

    private func recordMutation(_ name: String) throws {
        mutationCallCount += 1
        mutationCallsByName[name, default: 0] += 1
        if let err = mutationErrorAlways { throw err }
        if let err = mutationErrorOnNextCall { mutationErrorOnNextCall = nil; throw err }
    }

    func tap(snapshotID: String, elementID: String) async throws -> ToolResult {
        try recordMutation("tap")
        return try await inner.tap(snapshotID: snapshotID, elementID: elementID)
    }
    func doubleTap(snapshotID: String, elementID: String) async throws -> ToolResult {
        try recordMutation("doubleTap")
        return try await inner.doubleTap(snapshotID: snapshotID, elementID: elementID)
    }
    func longPress(snapshotID: String, elementID: String, durationSeconds: Double) async throws -> ToolResult {
        try recordMutation("longPress")
        return try await inner.longPress(snapshotID: snapshotID, elementID: elementID, durationSeconds: durationSeconds)
    }
    func swipe(snapshotID: String, elementID: String, direction: ScrollDirection) async throws -> ToolResult {
        try recordMutation("swipe")
        return try await inner.swipe(snapshotID: snapshotID, elementID: elementID, direction: direction)
    }
    func dragAndDrop(snapshotID: String, sourceElementID: String, destinationElementID: String, holdDurationSeconds: Double) async throws -> ToolResult {
        try recordMutation("dragAndDrop")
        return try await inner.dragAndDrop(snapshotID: snapshotID, sourceElementID: sourceElementID, destinationElementID: destinationElementID, holdDurationSeconds: holdDurationSeconds)
    }
    func typeText(snapshotID: String, elementID: String, text: String) async throws -> ToolResult {
        try recordMutation("typeText")
        return try await inner.typeText(snapshotID: snapshotID, elementID: elementID, text: text)
    }
    func clearText(snapshotID: String, elementID: String) async throws -> ToolResult {
        try recordMutation("clearText")
        return try await inner.clearText(snapshotID: snapshotID, elementID: elementID)
    }
    func scroll(snapshotID: String, containerID: String, direction: ScrollDirection) async throws -> ToolResult {
        try recordMutation("scroll")
        return try await inner.scroll(snapshotID: snapshotID, containerID: containerID, direction: direction)
    }
    func navigateBack(snapshotID: String, elementID: String) async throws -> ToolResult {
        try recordMutation("navigateBack")
        return try await inner.navigateBack(snapshotID: snapshotID, elementID: elementID)
    }
    func selectTab(snapshotID: String, elementID: String) async throws -> ToolResult {
        try recordMutation("selectTab")
        return try await inner.selectTab(snapshotID: snapshotID, elementID: elementID)
    }
    func dismissKeyboard(snapshotID: String, elementID: String) async throws -> ToolResult {
        try recordMutation("dismissKeyboard")
        return try await inner.dismissKeyboard(snapshotID: snapshotID, elementID: elementID)
    }
    func getElementDetails(snapshotID: String, elementID: String) async throws -> ToolResult {
        try recordMutation("getElementDetails")
        return try await inner.getElementDetails(snapshotID: snapshotID, elementID: elementID)
    }
    func captureScreenshot(reason: String) async throws -> (imagePath: String, observation: Observation?) {
        try recordMutation("captureScreenshot")
        return try await inner.captureScreenshot(reason: reason)
    }
    func inspectElements(snapshotID: String, expectedElements: [ScenarioExpectedElement]) async throws -> ToolResult {
        try recordMutation("inspectElements")
        return try await inner.inspectElements(snapshotID: snapshotID, expectedElements: expectedElements)
    }
}
