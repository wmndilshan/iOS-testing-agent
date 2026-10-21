import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@MainActor
struct RunHarness {
    let controller: ScenarioExecutionController
    let driver: SimulatedDriver
    let registry: ToolRegistry
    let scenario: SafeScenario
    let clock: TestClock

    init(clock: TestClock = TestClock()) {
        self.clock = clock
        self.controller = ScenarioExecutionController(clock: clock)
        self.scenario = ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!
        self.driver = SimulatedDriver(currentSnapshot: ProductFixtures.observation("init", [ProductFixtures.dropdown]))
        self.registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
    }

    func begin() {
        controller.startScenario(scenario)
        controller.configureRunContext(
            appIdentity: AppIdentity(bundleID: ProductFixtures.bundleID, displayName: "Example App"),
            simulatorID: "SIM-1", simulatorName: "iPhone 17", executionMode: "NON_LIVE_TEST"
        )
    }

    /// Proposes, approves and dispatches one step with the given fixture states. Returns the result.
    @discardableResult
    func runStep(target: UIElementSnapshot, before: Observation, after: Observation) async -> Result<ScenarioVerificationResult, DriverError> {
        if controller.activeObservation?.snapshotID != before.snapshotID { controller.recordObservation(before) }
        await driver.setSnapshot(before)   // the mock device is showing `before`
        let proposal = ActionProposal(
            scenarioID: scenario.id, snapshotID: before.snapshotID, elementID: target.id,
            expectedRole: target.role, expectedIdentifier: target.identifier, toolName: "tap_element",
            reason: "test proposal"
        )
        guard case .success = controller.handleProposal(proposal) else { return .failure(.actionFailed("proposal rejected")) }
        controller.approveCurrentStep(source: .testAuthority)
        await driver.queueNextSnapshot(after)
        return await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry)
    }

    func fullRun() async -> (s0: Observation, s1: Observation, s2: Observation) {
        begin()
        let s0 = ProductFixtures.observation("s0", [ProductFixtures.dropdown])
        let s1 = ProductFixtures.observation("s1", [ProductFixtures.closeButton])
        let s2 = ProductFixtures.observation("s2", [ProductFixtures.dropdown])
        await runStep(target: ProductFixtures.dropdown, before: s0, after: s1)
        await runStep(target: ProductFixtures.closeButton, before: s1, after: s2)
        return (s0, s1, s2)
    }
}

