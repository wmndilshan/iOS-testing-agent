import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("5. Security Boundary & Policy Tests")
struct SecurityBoundaryPolicyTests {
    let validator = TrustedActionValidator()



    @Test func testUnknownToolRejected() {
        let obs = Observation(
            snapshotID: "snap_tool",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [UIElementSnapshot(id: "btn", role: "button", identifier: "change-language-dropdown-button")]
        )
        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: "snap_tool",
            elementID: "btn",
            expectedRole: "button",
            toolName: "unregistered_destructive_tool",
            reason: "Trying unallowlisted tool"
        )

        let result = validator.validate(proposal: proposal, activeObservation: obs)
        #expect(!result.isValid)
        #expect(result.rejectionReason?.contains("not allowlisted") == true)
    }

    @Test func testStaleSnapshotRejected() {
        let obs = Observation(
            snapshotID: "fresh_snap_456",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [UIElementSnapshot(id: "btn", role: "button", identifier: "change-language-dropdown-button")]
        )
        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: "stale_snap_123",
            elementID: "btn",
            expectedRole: "button",
            toolName: "tap_element",
            reason: "Stale snapshot proposal"
        )

        let result = validator.validate(proposal: proposal, activeObservation: obs)
        #expect(!result.isValid)
        #expect(result.rejectionReason?.contains("Stale snapshot") == true)
    }

    @Test func testFabricatedElementRejected() {
        let obs = Observation(
            snapshotID: "snap_fab",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [UIElementSnapshot(id: "real_elem", role: "button", identifier: "change-language-dropdown-button")]
        )
        let proposal = ActionProposal(
            scenarioID: "SCENARIO-LANG-SHEET",
            snapshotID: "snap_fab",
            elementID: "synthetic_fake_elem_999",
            expectedRole: "button",
            toolName: "tap_element",
            reason: "Fabricated element"
        )

        let result = validator.validate(proposal: proposal, activeObservation: obs)
        #expect(!result.isValid)
        #expect(result.rejectionReason?.contains("does not exist in active snapshot") == true)
    }

    @Test func testLLMReadOnlyClassificationCannotOverrideTrustedPolicy() {
        let obs = Observation(
            snapshotID: "snap_ro_override",
            bundleID: "com.apple.mobilesafari",
            appState: .runningForeground,
            elements: [
                UIElementSnapshot(id: "elem_title", role: "staticText", label: "Log In UAT", identifier: "login-title")
            ]
        )
        // Scenario SCENARIO-INSPECT-LOGIN-SCREEN is defined as read-only (changesUIState = false) in catalog.
        // Even if LLM proposes tap_element claiming it's harmless, validator must reject it.
        let proposal = ActionProposal(
            scenarioID: "SCENARIO-INSPECT-LOGIN-SCREEN",
            snapshotID: "snap_ro_override",
            elementID: "elem_title",
            expectedRole: "staticText",
            toolName: "tap_element",
            reason: "LLM claims tapping title is read-only"
        )

        let result = validator.validate(proposal: proposal, activeObservation: obs)
        #expect(!result.isValid)
        #expect(result.rejectionReason?.contains("read-only") == true)
    }


}

// MARK: - 6. Required Test: Valid End-to-End Proposal (Section 25)
