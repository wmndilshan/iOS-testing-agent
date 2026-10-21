import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Forwards every driver call to a `SimulatedDriver`, except screenshots, which return a real temp file.
final class FileScreenshotDriver: DeviceDriver, @unchecked Sendable {
    let base: SimulatedDriver
    let screenshotURL: URL?
    /// When set, `tap` returns this result instead of delegating (to model a driver-reported failure).
    var tapOverride: ToolResult?

    init(base: SimulatedDriver = SimulatedDriver(), screenshotBytes: Data?) {
        self.base = base
        if let screenshotBytes {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).png")
            try? screenshotBytes.write(to: url)
            self.screenshotURL = url
        } else {
            self.screenshotURL = nil
        }
    }

    func captureObservation(bundleID: String) async throws -> Observation { try await base.captureObservation(bundleID: bundleID) }
    func tap(snapshotID: String, elementID: String) async throws -> ToolResult { if let tapOverride { return tapOverride }; return try await base.tap(snapshotID: snapshotID, elementID: elementID) }
    func doubleTap(snapshotID: String, elementID: String) async throws -> ToolResult { try await base.doubleTap(snapshotID: snapshotID, elementID: elementID) }
    func longPress(snapshotID: String, elementID: String, durationSeconds: Double) async throws -> ToolResult { try await base.longPress(snapshotID: snapshotID, elementID: elementID, durationSeconds: durationSeconds) }
    func swipe(snapshotID: String, elementID: String, direction: ScrollDirection) async throws -> ToolResult { try await base.swipe(snapshotID: snapshotID, elementID: elementID, direction: direction) }
    func dragAndDrop(snapshotID: String, sourceElementID: String, destinationElementID: String, holdDurationSeconds: Double) async throws -> ToolResult { try await base.dragAndDrop(snapshotID: snapshotID, sourceElementID: sourceElementID, destinationElementID: destinationElementID, holdDurationSeconds: holdDurationSeconds) }
    func typeText(snapshotID: String, elementID: String, text: String) async throws -> ToolResult { try await base.typeText(snapshotID: snapshotID, elementID: elementID, text: text) }
    func clearText(snapshotID: String, elementID: String) async throws -> ToolResult { try await base.clearText(snapshotID: snapshotID, elementID: elementID) }
    func scroll(snapshotID: String, containerID: String, direction: ScrollDirection) async throws -> ToolResult { try await base.scroll(snapshotID: snapshotID, containerID: containerID, direction: direction) }
    func getElementDetails(snapshotID: String, elementID: String) async throws -> ToolResult { try await base.getElementDetails(snapshotID: snapshotID, elementID: elementID) }
    func inspectElements(snapshotID: String, expectedElements: [ScenarioExpectedElement]) async throws -> ToolResult { try await base.inspectElements(snapshotID: snapshotID, expectedElements: expectedElements) }
    func captureScreenshot(reason: String) async throws -> (imagePath: String, observation: Observation?) {
        (screenshotURL?.path ?? "/nonexistent/none.png", try await base.captureObservation(bundleID: ProductFixtures.bundleID))
    }
}

enum IOSTestSupport {
    static func executor(driver: any DeviceDriver, store: (any ArtifactStoring)? = nil,
                         logger: any AppLogger = NullLogger(), clock: any ClockProtocol = TestClock()) -> IOSInteractionExecutor {
        IOSInteractionExecutor(driver: driver, artifactStore: store, logger: logger, clock: clock)
    }

    /// A snapshot with a hittable button, a disabled button and a non-hittable button.
    static func snapshot(_ tag: String = "ios") -> Observation {
        ProductFixtures.observation(tag, [
            ProductFixtures.element("ok", identifier: "ok-button", label: "OK"),
            ProductFixtures.element("off", identifier: "off-button", label: "Off", enabled: false),
            ProductFixtures.element("hidden", identifier: "hidden-button", label: "Hidden", hittable: false),
            ProductFixtures.element("field", role: "textField", identifier: "name-field", label: "Name"),
            ProductFixtures.element("list", role: "scrollView", identifier: "the-list", label: "List"),
        ])
    }

    static func target(_ obs: Observation, _ id: String) -> ElementTarget { ElementTarget(snapshotID: obs.snapshotID, elementID: id) }
}
