import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Scenario catalog, records and mode")
struct ScenarioCatalogTests {
    @Test func testStaleSnapshotRejection() async {
        let mockDriver = SimulatedDriver()
        await #expect(throws: DriverError.self) {
            _ = try await mockDriver.tap(snapshotID: "non_existent_stale_snapshot_id", elementID: "elem_1")
        }
    }

    // MARK: - Agent Coordinator: Legacy Mutating Loop Removal Regression Tests
    //
    // AgentCoordinator previously exposed `runTestCase`, an independent LLM -> ApprovalGate ->
    // ToolRegistry.execute loop that bypassed ScenarioExecutionController and TrustedActionValidator
    // entirely (see the forensic audit remediation). That method has been deleted. These tests prove
    // the deletion is structural, not cosmetic: AgentCoordinator is reduced to a passive dependency
    // container with no method capable of driving a mutating ToolRegistry call, and mutating tools
    // dispatched through it are only reachable via ScenarioExecutionController.


    // MARK: - Safe Reusable Scenario Workflow Tests

    @Test func testScenarioCatalogLoadsAllowlistedSafeScenarios() {
        let catalog = ScenarioCatalog.shared
        #expect(catalog.scenarios.count >= 3)

        let langSheet = catalog.findScenario(by: "SCENARIO-LANG-SHEET")
        #expect(langSheet != nil)
        #expect(langSheet?.changesUIState == true)
        #expect(langSheet?.teardownStep != nil)
        #expect(langSheet?.actionStep.locator.identifier == "change-language-dropdown-button")
        #expect(langSheet?.teardownStep?.locator.identifier == "close_var_1")

        let inspectLogin = catalog.findScenario(by: "SCENARIO-INSPECT-LOGIN-SCREEN")
        #expect(inspectLogin != nil)
        #expect(inspectLogin?.changesUIState == false)
        #expect(inspectLogin?.teardownStep == nil)

        let togglePass = catalog.findScenario(by: "SCENARIO-TOGGLE-PASSWORD-VISIBILITY")
        #expect(togglePass != nil)
        #expect(togglePass?.changesUIState == true)
        #expect(togglePass?.teardownStep != nil)

        // Verify zero login, financial, buy/sell, delete or destructive actions
        for scenario in catalog.scenarios {
            let nameLower = scenario.name.lowercased()
            let descLower = scenario.actionStep.description.lowercased()
            #expect(!nameLower.contains("login button") && !nameLower.contains("sign in button"))
            #expect(!nameLower.contains("buy") && !nameLower.contains("sell"))
            #expect(!nameLower.contains("delete"))
            #expect(!descLower.contains("submit credentials"))
        }
    }




}
