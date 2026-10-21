import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Driver element resolution safety")
struct DriverElementResolutionTests {
    @Test func testTapElementRejectsMissingOrInvalidArguments() async throws {
        let config = try Configuration.load()
        let mockDriver = SimulatedDriver()
        let registry = ToolRegistry(projectRoot: config.projectRoot, driver: mockDriver)

        // Missing arguments
        let emptyCall = ToolCall(id: "c1", name: "tap_element", arguments: [:])
        await #expect(throws: ToolRegistryError.self) {
            _ = try await registry.execute(emptyCall, authorization: AuthorizationFixture.authorized(for: emptyCall))
        }

        // Missing elementID
        let missingElementID = ToolCall(id: "c2", name: "tap_element", arguments: [
            "snapshotID": .string("snap_1")
        ])
        await #expect(throws: ToolRegistryError.self) {
            _ = try await registry.execute(missingElementID, authorization: AuthorizationFixture.authorized(for: missingElementID))
        }

        // Empty string arguments
        let emptyStrings = ToolCall(id: "c3", name: "tap_element", arguments: [
            "snapshotID": .string(""),
            "elementID": .string("")
        ])
        await #expect(throws: ToolRegistryError.self) {
            _ = try await registry.execute(emptyStrings, authorization: AuthorizationFixture.authorized(for: emptyStrings))
        }

        // Non-string arguments
        let invalidTypes = ToolCall(id: "c4", name: "tap_element", arguments: [
            "snapshotID": .int(123),
            "elementID": .bool(true)
        ])
        await #expect(throws: ToolRegistryError.self) {
            _ = try await registry.execute(invalidTypes, authorization: AuthorizationFixture.authorized(for: invalidTypes))
        }
    }

    @Test func testDuplicateLabelsDoNotSelectArbitraryElement() async {
        let mockDriver = SimulatedDriver()
        // Two elements sharing identical role and label with no unique native identifier
        let ambiguousSnap = Observation(
            snapshotID: "snap_ambig",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "btn_copy_1", role: "button", label: "Copy"),
                UIElementSnapshot(id: "btn_copy_2", role: "button", label: "Copy")
            ]
        )
        await mockDriver.setSnapshot(ambiguousSnap)

        do {
            _ = try await mockDriver.tap(snapshotID: "snap_ambig", elementID: "btn_copy_1")
            #expect(Bool(false), "Expected ambiguousElement error to be thrown")
        } catch let error as DriverError {
            if case .ambiguousElement(let ident, let count, let candidates) = error {
                #expect(ident == "Copy")
                #expect(count == 2)
                #expect(candidates.count == 2)
            } else {
                #expect(Bool(false), "Expected .ambiguousElement, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func testElementTypeIsCheckedOnResolution() async {
        let mockDriver = SimulatedDriver()
        // Locator expects a button, but current element has been mutated to slider
        let locator = ElementLocator(snapshotID: "snap_mock_1", elementID: "elem_3", role: "button")
        await mockDriver.setLocator(locator)

        let mutatedSnap = Observation(
            snapshotID: "snap_mock_1",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "elem_3", role: "slider", label: "Log In", identifier: "login_button")
            ]
        )
        await mockDriver.setSnapshot(mutatedSnap)
        // Ensure locator still says "button"
        await mockDriver.setLocator(locator)

        do {
            _ = try await mockDriver.tap(snapshotID: "snap_mock_1", elementID: "elem_3")
            #expect(Bool(false), "Expected typeMismatch error")
        } catch let error as DriverError {
            if case .typeMismatch(let expected, let actual, let id) = error {
                #expect(expected == "button")
                #expect(actual == "slider")
                #expect(id == "elem_3")
            } else {
                #expect(Bool(false), "Expected .typeMismatch, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func testStaleSnapshotIDIsRejected() async {
        let mockDriver = SimulatedDriver()
        do {
            _ = try await mockDriver.tap(snapshotID: "stale_snap_vintage_1999", elementID: "elem_3")
            #expect(Bool(false), "Expected staleSnapshot error")
        } catch let error as DriverError {
            if case .staleSnapshot(let req, let curr) = error {
                #expect(req == "stale_snap_vintage_1999")
                #expect(curr == "snap_mock_1")
            } else {
                #expect(Bool(false), "Expected .staleSnapshot, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func testMissingElementIsRejected() async {
        let mockDriver = SimulatedDriver()
        do {
            _ = try await mockDriver.tap(snapshotID: "snap_mock_1", elementID: "ghost_element_404")
            #expect(Bool(false), "Expected elementNotFound error")
        } catch let error as DriverError {
            if case .elementNotFound(let id) = error {
                #expect(id == "ghost_element_404")
            } else {
                #expect(Bool(false), "Expected .elementNotFound, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func testNonHittableElementIsRejected() async {
        let mockDriver = SimulatedDriver()
        let obscuredSnap = Observation(
            snapshotID: "snap_obscured",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "elem_obscured", role: "button", label: "Hidden Button", isHittable: false)
            ]
        )
        await mockDriver.setSnapshot(obscuredSnap)

        do {
            _ = try await mockDriver.tap(snapshotID: "snap_obscured", elementID: "elem_obscured")
            #expect(Bool(false), "Expected elementNotHittable error")
        } catch let error as DriverError {
            if case .elementNotHittable(let id) = error {
                #expect(id == "elem_obscured")
            } else {
                #expect(Bool(false), "Expected .elementNotHittable, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func testTextHeadingIsNotTreatedAsButton() async throws {
        let mockDriver = SimulatedDriver()
        // Screen contains both a staticText heading and a button sharing the label "Log In"
        let headingSnap = Observation(
            snapshotID: "snap_heading_vs_btn",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "elem_heading", role: "staticText", label: "Log In", identifier: "login_heading"),
                UIElementSnapshot(id: "elem_button", role: "button", label: "Log In", identifier: "login_button")
            ]
        )
        await mockDriver.setSnapshot(headingSnap)

        let headingLocator = await mockDriver.getLocator(elementID: "elem_heading")
        let buttonLocator = await mockDriver.getLocator(elementID: "elem_button")

        #expect(headingLocator?.role == "staticText")
        #expect(buttonLocator?.role == "button")
        #expect(headingLocator?.elementID != buttonLocator?.elementID)

        // Tapping the button succeeds and does not touch heading
        let btnResult = try await mockDriver.tap(snapshotID: "snap_heading_vs_btn", elementID: "elem_button")
        #expect(btnResult.status == .success)

        // If an action requires button, attempting to re-resolve heading as a button fails type check
        await mockDriver.setLocator(ElementLocator(snapshotID: "snap_heading_vs_btn", elementID: "elem_heading", role: "button"))
        await #expect(throws: DriverError.typeMismatch(expected: "button", actual: "staticText", elementID: "elem_heading")) {
            _ = try await mockDriver.tap(snapshotID: "snap_heading_vs_btn", elementID: "elem_heading")
        }
    }

}

@Suite("Live driver never reports success for unimplemented actions")
struct LiveDriverFailClosedTests {






}
