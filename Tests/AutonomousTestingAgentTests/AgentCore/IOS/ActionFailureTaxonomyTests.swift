import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Action failure taxonomy")
struct ActionFailureTaxonomyTests {

    @Test func testTheTaxonomyContainsEveryRequiredKindOnce() {
        let required = ["targetNotFound", "targetNotHittable", "targetDisabled", "staleSnapshot", "invalidArguments", "unsupportedCapability", "timeout",
                        "keyboardUnavailable", "overlayNotFound", "gestureFailed", "driverFailure", "simulatorFailure", "xctestFailure", "verificationFailed",
                        "authorizationFailed", "observationFailed", "noProgress", "cancelled"]
        #expect(Set(ActionFailureKind.allCases.map(\.rawValue)) == Set(required) && ActionFailureKind.allCases.count == required.count)
    }

    @Test func testEveryKindMapsToANeutralErrorCategory() {
        for kind in ActionFailureKind.allCases { _ = kind.category }
        #expect(ActionFailureKind.staleSnapshot.category == .observation && ActionFailureKind.simulatorFailure.category == .simulator)
        #expect(ActionFailureKind.timeout.category == .timeout && ActionFailureKind.authorizationFailed.category == .authorization)
    }

    @Test func testDriverErrorsMapOneToOne() {
        let map: [(DriverError, ActionFailureKind)] = [
            (.staleSnapshot(requested: "a", current: "b"), .staleSnapshot), (.elementNotFound("e"), .targetNotFound),
            (.elementNotHittable("e"), .targetNotHittable), (.elementDisabled("e"), .targetDisabled),
            (.typeMismatch(expected: "a", actual: "b", elementID: "e"), .targetNotFound), (.ambiguousElement("e", count: 2), .targetNotFound),
            (.actionFailed("x"), .xctestFailure), (.simulatorNotAvailable("u"), .simulatorFailure), (.observationFailed("x"), .observationFailed),
            (.unsupportedCapability("x"), .unsupportedCapability), (.timedOut("x"), .timeout)]
        for (error, kind) in map { #expect(ActionFailureKind.of(error) == kind, "\(error)") }
    }

    @Test func testToolAndPlatformErrorsMap() {
        #expect(ActionFailureKind.of(ToolRegistryError.invalidArguments("x")) == .invalidArguments)
        #expect(ActionFailureKind.of(ToolRegistryError.authorizationRequired("t")) == .authorizationFailed)
        #expect(ActionFailureKind.of(ToolRegistryError.authorizationMismatch("t")) == .authorizationFailed)
        #expect(ActionFailureKind.of(ToolRegistryError.toolNotFound("t")) == .unsupportedCapability)
        #expect(ActionFailureKind.of(CancellationError()) == .cancelled)
        struct Other: Error {}
        #expect(ActionFailureKind.of(Other()) == .driverFailure)
    }

    @Test func testDriverErrorsClassifyForRecoveryAndCategories() {
        #expect(DriverError.unsupportedCapability("x").errorCategory == .toolUnavailable && DriverError.timedOut("x").errorCategory == .timeout)
        #expect(FailureClassifier().classify(.unsupportedCapability("x")) == .xctestFailed)
        #expect(DriverError.unsupportedCapability("swipe").localizedDescription.contains("Unsupported capability"))
    }

    @Test func testDriverReportedFailuresAreClassifiedAndRedactedInTheStoredResult() async throws {
        let driver = FileScreenshotDriver(screenshotBytes: nil)
        driver.tapOverride = ToolResult(callID: "c", status: .failed, summary: "tap failed: password=hunter2 api_key=AIzaSyD-1234567890abcdefghijklmnop")
        let exec = try await IOSTestSupport.executor(driver: driver).execute(
            .tap(TapAction(target: ElementTarget(snapshotID: "s", elementID: "e"))), context: IOSActionContext(toolName: "tap_element"))
        #expect(!exec.result.success && exec.result.failure?.kind == .xctestFailure)
        let stored = exec.result.failure?.message ?? ""
        #expect(!stored.contains("hunter2") && !stored.contains("AIzaSyD"))
    }
}
