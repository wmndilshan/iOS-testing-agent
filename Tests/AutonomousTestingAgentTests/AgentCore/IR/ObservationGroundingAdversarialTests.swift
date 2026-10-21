import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Observation-grounding contract, Part K: adversarial LLM-proposed target strings. Every case must fail closed — grounding does
/// not parse or interpret these strings in any special way (no XPath engine, no shell, no coordinate
/// parser exists in `ObservationGroundingService`), so the proof is simply that none of them ever produces
/// `.grounded` against a real vocabulary that does not literally contain them, and none of them crashes.
@Suite("IR.28 Observation Grounding — Adversarial")
struct ObservationGroundingAdversarialTests {
    static func vocabulary() -> ObservedUIVocabulary {
        ObservedUIVocabulary.derive(from: Observation(
            snapshotID: "snap_real", bundleID: "com.autonomous.agent.fixture", appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "e1", role: "button", label: "Tap target", identifier: "fixture.tap.target"),
                UIElementSnapshot(id: "e2", role: "other", label: "tap:idle", identifier: "fixture.tap.status")
            ]
        ))
    }

    static let adversarialIdentifiers: [String] = [
        "status_label",                                              // guessed/plausible identifier
        "username_field",                                            // guessed identifier from prompt example
        "3F2504E0-4F89-11D3-9A0C-0305E82C3301",                       // UUID-like fake identifier
        "100,200",                                                   // coordinate-shaped string
        "x=100;y=200",                                               // coordinate-shaped string, alt form
        "//XCUIElementTypeButton[@name='Tap target']",                // XPath-like string
        "#tap-target.primary-button",                                // CSS-selector-like string
        "; rm -rf / #",                                              // shell command
        "$(xcrun simctl erase all)",                                 // xcrun command
        "`xcodebuild test -scheme evil`",                            // xcodebuild command
        "app.buttons[\"Tap target\"].tap()",                          // literal XCTest source
        "XCUIElement.privateTapAtPoint(_:)",                          // private-API-looking name
        "../../../etc/passwd",                                       // arbitrary path traversal
        "fixture.tap.target/../fixture.text.field",                  // arbitrary target "path"
        "fixture.text.field",                                        // real identifier, but from a DIFFERENT fixture screen (not in this vocabulary)
        ""                                                            // empty string
    ]

    @Test("Every adversarial identifier fails closed (never grounded) against a real vocabulary that does not contain it, and none crashes", arguments: adversarialIdentifiers)
    func testAdversarialIdentifierFailsClosed(_ fabricated: String) {
        let ir = TestIR(testKey: "T", title: "t", steps: [
            IRStep(id: "s1", sourceStepNumber: 1, intent: "tap", action: .tap, target: IRTarget(role: "button", identifier: fabricated.isEmpty ? nil : fabricated))
        ])
        let result = ObservationGroundingService.ground(ir: ir, vocabulary: Self.vocabulary())
        #expect(result.issues.first?.status != .grounded, "'\(fabricated)' must never ground")
    }

    @Test("Adversarial identifiers used as verification signal identifiers (labelBecame) also fail closed — this is the exact shape of Live-execution contract's real finding", arguments: adversarialIdentifiers.filter { !$0.isEmpty })
    func testAdversarialSignalIdentifierFailsClosed(_ fabricated: String) {
        let ir = TestIR(testKey: "T", title: "t", steps: [
            IRStep(id: "s1", sourceStepNumber: 1, intent: "tap", action: .tap, target: IRTarget(role: "button", identifier: "fixture.tap.target"),
                  verification: IRVerification(description: "d", signals: [.labelBecame(identifier: fabricated, to: "tap:tapped")]))
        ])
        let result = ObservationGroundingService.ground(ir: ir, vocabulary: Self.vocabulary())
        let signalIssue = result.issues.first { $0.kind == "labelBecame" }
        #expect(signalIssue?.status != .grounded, "'\(fabricated)' must never ground as a signal identifier")
    }

    @Test("A stale identifier that was real in an EARLIER snapshot's vocabulary but is absent from the CURRENT one is unresolved, not silently accepted")
    func testStaleIdentifierFromPreviousSnapshotIsUnresolved() {
        let earlierVocabulary = ObservedUIVocabulary(snapshotID: "snap_earlier", bundleID: "com.autonomous.agent.fixture", elements: [
            ObservedElementReference(elementID: "e9", accessibilityIdentifier: "fixture.overlay.dismiss", label: "Close", role: "button", state: ObservedElementState(isEnabled: true, isHittable: true, isSelected: nil))
        ])
        // The CURRENT vocabulary (post-dismiss) no longer contains that element at all — exactly what
        // happens once an overlay is dismissed.
        let currentVocabulary = Self.vocabulary()
        #expect(earlierVocabulary.elements.contains { $0.accessibilityIdentifier == "fixture.overlay.dismiss" })

        let ir = TestIR(testKey: "T", title: "t", steps: [
            IRStep(id: "s1", sourceStepNumber: 1, intent: "dismiss", action: .tap, target: IRTarget(role: "button", identifier: "fixture.overlay.dismiss"))
        ])
        let result = ObservationGroundingService.ground(ir: ir, vocabulary: currentVocabulary)
        #expect(result.issues.first?.status == .unresolved, "an identifier real only in a PRIOR snapshot must not ground against the current one")
    }

    @Test("Coordinates cannot even be represented — IRTarget has no x/y field to decode, so a coordinate-fallback path structurally cannot exist in the IR wire format")
    func testCoordinatesCannotBeRepresentedInIRTarget() throws {
        let json = """
        {"role": "button", "x": 100, "y": 200}
        """.data(using: .utf8)!
        // A strict decode either ignores unknown keys (Codable's default) or fails; either way, no `x`/`y`
        // value ever reaches a live dispatch, because `IRTarget`/`ScenarioLocator` have no such field for it
        // to land in.
        let target = try? JSONDecoder().decode(IRTarget.self, from: json)
        #expect(target?.role == "button")
        let mirror = Mirror(reflecting: target ?? IRTarget(role: "button"))
        #expect(!mirror.children.contains { $0.label == "x" || $0.label == "y" })
    }
}
