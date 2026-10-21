import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Observation snapshot structure and limits")
struct ObservationSnapshotTests {
    @Test func testObservationDepthAndCountLimits() {
        var rawElements: [UIElementSnapshot] = []
        for i in 0..<100 {
            rawElements.append(UIElementSnapshot(
                id: "el_\(i)",
                role: "button",
                label: "Button \(i)",
                depth: i < 50 ? 2 : 10 // depth > 6 will be filtered
            ))
        }

        let sanitized = ObservationFilter.sanitize(elements: rawElements, maxDepth: 6, maxElements: 20)
        #expect(sanitized.count == 20)
        #expect(sanitized.allSatisfy { $0.depth <= 6 })
    }

    @Test func testAccessibilityTreeCollectionReturnsStructuredSnapshot() async throws {
        let mockDriver = SimulatedDriver()
        let observation = try await mockDriver.captureObservation(bundleID: "com.apple.mobilesafari")

        #expect(!observation.snapshotID.isEmpty)
        #expect(observation.elements.count >= 4)
        #expect(observation.elements.contains { $0.role == "textField" && $0.label == "Username" })
        #expect(observation.elements.contains { $0.role == "secureTextField" && $0.isSecure == true })
        #expect(observation.elements.contains { $0.role == "button" && $0.label == "Log In" })
        #expect(observation.elements.contains { $0.role == "slider" && $0.label == "Slide to Buy" })
    }

    @Test func testSnapshotIDsAreUnique() async throws {
        let obs1 = Observation(
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: []
        )
        let obs2 = Observation(
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: []
        )

        #expect(!obs1.snapshotID.isEmpty)
        #expect(!obs2.snapshotID.isEmpty)
        #expect(obs1.snapshotID != obs2.snapshotID)
    }

    @Test func testElementIDsScopedToSnapshot() async throws {
        let mockDriver = SimulatedDriver()
        let currentSnap = await mockDriver.currentSnapshot
        let locator = await mockDriver.getLocator(elementID: "elem_1")

        #expect(locator != nil)
        #expect(locator?.elementID == "elem_1")
        #expect(locator?.snapshotID == currentSnap.snapshotID)
        #expect(locator?.role == "textField")
    }

    @Test func testTreeDepthAndCountLimitsEnforced() {
        var rawElements: [UIElementSnapshot] = []
        for i in 0..<75 {
            rawElements.append(
                UIElementSnapshot(
                    id: "el_\(i)",
                    role: "button",
                    label: "Button \(i)",
                    depth: i < 40 ? 2 : 8
                )
            )
        }

        let (sanitized, isTruncated) = ObservationFilter.sanitizeWithTruncation(
            elements: rawElements,
            maxDepth: 6,
            maxElements: 50
        )

        #expect(sanitized.count <= 50)
        #expect(sanitized.allSatisfy { $0.depth <= 6 })
        #expect(isTruncated == true)
    }

    @Test("Default observation bounds retain complete ordinary accessibility screens")
    func testDefaultBoundsDoNotDropElementsAfterTheOldFiftyElementLimit() {
        let raw = (0..<80).map { index in
            UIElementSnapshot(
                id: "el_\(index)", parentID: index == 0 ? nil : "el_0",
                role: index == 63 ? "staticText" : "other",
                label: index == 63 ? "Log In UAT" : nil,
                depth: index == 0 ? 0 : (index == 63 ? 12 : 7)
            )
        }
        let result = ObservationFilter.sanitizeWithTruncation(elements: raw)
        #expect(result.elements.count == 80)
        #expect(result.elements.contains { $0.label == "Log In UAT" && $0.depth == 12 })
        #expect(!result.isTruncated)
    }
}
