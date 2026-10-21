import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// The approval spine driven directly: `ScenarioExecutionController` + `SimulatedDriver` + `ToolRegistry`, no UI state.
/// A proposal becomes a pending approval, only a granted approval can be dispatched, and only a verified step advances.
@Suite("Approval spine (controller level)")
@MainActor
struct ApprovalSpineTests {
    nonisolated static let bundle = "com.autonomous.agent.fixture"

    nonisolated static func screen(_ snapshotID: String, selected: String = "first") -> Observation {
        Observation(snapshotID: snapshotID, bundleID: bundle, appState: .runningForeground, elements: [
            UIElementSnapshot(id: "e1", role: "other", label: "tab:\(selected)", identifier: "fixture.tabs.status"),
            UIElementSnapshot(id: "e2", role: "button", label: "First", identifier: "tab.first"),
            UIElementSnapshot(id: "e3", role: "button", label: "Second", identifier: "tab.second", isEnabled: true),
            // Each tab shows its own content, so a real tab change also changes the set of elements (that is "progress").
            UIElementSnapshot(id: "content_\(selected)", role: "staticText", label: "\(selected) content")
        ])
    }

    nonisolated static func status(_ label: String) -> ScenarioStepVerification {
        ScenarioStepVerification(description: "status shows \(label)", requiredElements: [
            ScenarioExpectedElement(role: "other", identifier: "fixture.tabs.status", label: label, requireNonZeroBounds: false)])
    }

    /// Two ordered steps: tap Second (the tab status becomes "tab:second"), then tap First (it becomes "tab:first").
    @MainActor struct Rig {
        let clock = TestClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let driver: SimulatedDriver
        let registry: ToolRegistry
        let controller: ScenarioExecutionController
        let start: Observation

        init() {
            start = ApprovalSpineTests.screen("snap_0")
            driver = SimulatedDriver(currentSnapshot: start)
            registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
            let second = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element",
                                      locator: ScenarioLocator(role: "button", label: "Second"),
                                      verification: ApprovalSpineTests.status("tab:second"),
                                      signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:second")])
            let first = ScenarioStep(id: "s2", name: "tap first", description: "d", toolName: "tap_element",
                                     locator: ScenarioLocator(role: "button", label: "First"),
                                     verification: ApprovalSpineTests.status("tab:first"),
                                     signals: [.labelBecame(identifier: "fixture.tabs.status", to: "tab:first")])
            let scenario = SafeScenario(id: "SPINE", name: "spine", purpose: "p", initialStateRequirement: "", expectedPostActionState: "",
                                        changesUIState: true, steps: [second, first])
            let catalog = ScenarioCatalog(scenarios: [scenario])
            controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
            controller.clock = clock
            // Keep the 120 s scenario budget out of the way of the 120 s approval TTL tests.
            controller.scenarioTimeoutSeconds = 3600
            _ = controller.startScenario(scenario)
            controller.recordObservation(start)
        }

        func proposal(element: String = "e3", role: String = "button", identifier: String? = "Second", snapshot: String? = nil,
                      tool: String = "tap_element", stepIndex: Int? = 0, stepID: String? = "s1",
                      arguments: [String: AnyCodableValue] = [:]) -> ActionProposal {
            ActionProposal(scenarioID: "SPINE", snapshotID: snapshot ?? controller.activeObservation?.snapshotID ?? "", elementID: element,
                           expectedRole: role, expectedIdentifier: identifier, toolName: tool, arguments: arguments, reason: "r",
                           stepIndex: stepIndex, stepID: stepID)
        }

        @discardableResult
        func propose(_ p: ActionProposal? = nil) -> Result<HITLApprovalRequest, LLMProposalPipelineError> {
            controller.handleProposal(p ?? proposal())
        }

        func dispatch() async -> Result<ScenarioVerificationResult, DriverError> {
            await controller.dispatchCurrentStep(driver: driver, toolRegistry: registry, bundleID: ApprovalSpineTests.bundle, isLive: false)
        }

        func taps() async -> Int { await driver.invokedActionCount["tap"] ?? 0 }
    }

    // MARK: (a) No dispatch without an approved request

    @Test func testDispatchWithoutAnyProposalNeverReachesTheDriver() async {
        let rig = Rig()
        let result = await rig.dispatch()
        guard case .failure = result else { Issue.record("expected failure"); return }
        #expect(await rig.taps() == 0)
    }

    @Test func testAProposalAloneIsPendingAndNeverTouchesTheDriver() async throws {
        let rig = Rig()
        let request = try rig.propose().get()
        #expect(request.status == .pending)
        #expect(rig.controller.activeApproval?.status == .pending)
        #expect(await rig.taps() == 0)
    }

    @Test func testPendingButUnapprovedRequestCannotBeDispatched() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        let result = await rig.dispatch()
        guard case .failure = result else { Issue.record("a pending approval must not dispatch"); return }
        #expect(await rig.taps() == 0)
        #expect(rig.controller.currentStepIndex == 0)
    }

    @Test func testApprovedRequestIsDispatchedExactlyOnce() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        #expect(rig.controller.activeApproval?.status == .approved)
        await rig.driver.queueNextSnapshot(Self.screen("snap_1", selected: "second"))
        _ = await rig.dispatch()
        #expect(await rig.taps() == 1)
    }

    @Test func testARejectedProposalLeavesNothingToApproveOrDispatch() async {
        let rig = Rig()
        guard case .failure = rig.propose(rig.proposal(element: "ghost")) else { Issue.record("expected rejection"); return }
        #expect(rig.controller.activeApproval == nil)
        rig.controller.approveCurrentStep(source: .testAuthority)
        #expect(rig.controller.activeApproval == nil, "approving with no request must not invent one")
        _ = await rig.dispatch()
        #expect(await rig.taps() == 0)
    }

    @Test func testApprovalIsBoundToTheProposedTargetAndSnapshot() throws {
        let rig = Rig()
        let request = try rig.propose().get()
        #expect(request.snapshotID == "snap_0")
        #expect(request.toolName == "tap_element")
        #expect(request.targetLocator?.elementID == "e3")
        #expect(request.boundTestCaseID == "SPINE")
    }

    // MARK: (b) Single use and expiry

    @Test func testApprovalIsSingleUse() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        await rig.driver.queueNextSnapshot(Self.screen("snap_1", selected: "second"))
        _ = await rig.dispatch()
        #expect(await rig.taps() == 1)
        // The same approval cannot be replayed, whatever the outcome of the first dispatch was.
        _ = await rig.dispatch()
        #expect(await rig.taps() == 1, "a consumed approval must not reach the driver again")
    }

    @Test func testReProposingAnExecutedActionOnTheSameSnapshotIsRefused() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        // The screen does not change, so the step stays unverified and the same snapshot is still current.
        _ = await rig.dispatch()
        let again = rig.propose()
        guard case .failure = again else { Issue.record("expected the repeat to be refused"); return }
        #expect(await rig.taps() == 1)
    }

    @Test func testApprovalLifetimeIs120Seconds() throws {
        let rig = Rig()
        let request = try rig.propose().get()
        #expect(ApprovalPolicy.tokenTimeToLive == 120)
        #expect(request.expiresAt == rig.clock.now().addingTimeInterval(120))
    }

    @Test func testApprovingAfterTheTTLExpiresTheRequest() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.clock.advance(by: 121)
        rig.controller.approveCurrentStep(source: .testAuthority)
        #expect(rig.controller.activeApproval?.status == .expired)
        _ = await rig.dispatch()
        #expect(await rig.taps() == 0)
    }

    @Test func testAnApprovedRequestThatExpiresBeforeDispatchIsNotExecuted() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.clock.advance(by: 30)
        rig.controller.approveCurrentStep(source: .testAuthority)
        #expect(rig.controller.activeApproval?.status == .approved)
        rig.clock.advance(by: 91)
        let result = await rig.dispatch()
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.localizedDescription.localizedCaseInsensitiveContains("expired"))
        #expect(rig.controller.activeApproval?.status == .expired)
        #expect(await rig.taps() == 0)
    }

    @Test func testAnApprovalStillInsideItsTTLIsExecuted() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        rig.clock.advance(by: 119)
        await rig.driver.queueNextSnapshot(Self.screen("snap_1", selected: "second"))
        _ = await rig.dispatch()
        #expect(await rig.taps() == 1)
    }

    @Test func testAnExpiredRequestCannotBeRevivedByApprovingAgain() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.clock.advance(by: 125)
        rig.controller.approveCurrentStep(source: .testAuthority)
        rig.controller.approveCurrentStep(source: .testAuthority)
        #expect(rig.controller.activeApproval?.status == .expired)
        _ = await rig.dispatch()
        #expect(await rig.taps() == 0)
    }

    // MARK: (c) A stale snapshot invalidates the approval

    @Test func testANewSnapshotDropsAPendingApproval() throws {
        let rig = Rig()
        _ = try rig.propose().get()
        #expect(rig.controller.activeApproval != nil)
        rig.controller.recordObservation(Self.screen("snap_other"))
        #expect(rig.controller.activeApproval == nil)
    }

    @Test func testANewSnapshotAfterApprovalBlocksDispatch() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        rig.controller.recordObservation(Self.screen("snap_other"))
        let result = await rig.dispatch()
        guard case .failure = result else { Issue.record("a stale approval must not dispatch"); return }
        #expect(await rig.taps() == 0)
    }

    @Test func testAProposalBoundToAnOldSnapshotIsRejected() {
        let rig = Rig()
        rig.controller.recordObservation(Self.screen("snap_new"))
        guard case .failure = rig.propose(rig.proposal(snapshot: "snap_0")) else { Issue.record("expected rejection"); return }
        #expect(rig.controller.activeApproval == nil)
    }

    @Test func testReRecordingTheSameSnapshotKeepsAPendingApproval() throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.recordObservation(rig.start)
        #expect(rig.controller.activeApproval?.status == .pending)
    }

    // MARK: (d) The validator rejects what is not in the observation

    @Test func testValidatorRejectsAnElementThatIsNotOnScreen() {
        let rig = Rig()
        guard case .failure(let error) = rig.propose(rig.proposal(element: "e99")) else { Issue.record("expected rejection"); return }
        #expect(error.localizedDescription.contains("does not exist"))
    }

    @Test func testValidatorRejectsARoleThatDoesNotMatchTheElement() {
        let rig = Rig()
        guard case .failure(let error) = rig.propose(rig.proposal(role: "switch")) else { Issue.record("expected rejection"); return }
        #expect(error.localizedDescription.contains("role mismatch"))
    }

    @Test func testValidatorRejectsAnIdentifierThatDoesNotMatchTheElement() {
        let rig = Rig()
        guard case .failure(let error) = rig.propose(rig.proposal(identifier: "tab.third")) else { Issue.record("expected rejection"); return }
        #expect(error.localizedDescription.contains("mismatch"))
    }

    @Test func testValidatorRejectsAnElementThatIsNotTheStepsTarget() {
        let rig = Rig()
        // "First" exists on screen with the right role and identifier, but the active step is "tap Second".
        guard case .failure = rig.propose(rig.proposal(element: "e2", identifier: "tab.first")) else { Issue.record("expected rejection"); return }
        #expect(rig.controller.activeApproval == nil)
    }

    @Test func testValidatorRejectsAToolThatIsNotTheStepsTool() {
        let rig = Rig()
        guard case .failure = rig.propose(rig.proposal(tool: "type_text")) else { Issue.record("expected rejection"); return }
        #expect(rig.controller.activeApproval == nil)
    }

    @Test func testValidatorRejectsAProposalWithNoObservation() {
        let validator = TrustedActionValidator(catalog: ScenarioCatalog(scenarios: []))
        let verdict = validator.validate(proposal: ActionProposal(scenarioID: "X", snapshotID: "s", elementID: "e", expectedRole: "button", toolName: "tap_element", reason: "r"),
                                         activeObservation: nil)
        guard case .rejected = verdict else { Issue.record("expected rejection"); return }
    }

    @Test func testAProposalCannotSupplyTrustedIdentifiersAsArguments() {
        let rig = Rig()
        guard case .failure(let error) = rig.propose(rig.proposal(arguments: ["elementID": .string("e2")])) else { Issue.record("expected rejection"); return }
        #expect(error.localizedDescription.contains("trusted parameter"))
    }

    @Test func testAProposalOutOfStepOrderIsRejected() {
        let rig = Rig()
        guard case .failure = rig.propose(rig.proposal(element: "e2", identifier: "tab.first", stepIndex: 1, stepID: "s2")) else { Issue.record("expected rejection"); return }
        #expect(rig.controller.currentStepIndex == 0)
    }

    // MARK: (e) A denied step dispatches nothing and records a failure

    @Test func testADeniedStepDispatchesNothing() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.denyCurrentStep(reason: "no")
        #expect(rig.controller.activeApproval?.status == .denied)
        let result = await rig.dispatch()
        guard case .failure = result else { Issue.record("a denied step must not dispatch"); return }
        #expect(await rig.taps() == 0)
        #expect(rig.controller.currentStepIndex == 0)
    }

    @Test func testADenialIsRecordedAsAFailure() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.denyCurrentStep(reason: "no")
        #expect(rig.controller.stepLifecycle == .actionFailed)
        #expect(rig.controller.lastFailureClass == .approvalDenied)
        #expect(await rig.taps() == 0)
    }

    @Test func testADeniedRequestCannotBeApprovedAfterwards() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.denyCurrentStep(reason: "no")
        rig.controller.approveCurrentStep(source: .testAuthority)
        #expect(rig.controller.activeApproval?.status == .denied)
        _ = await rig.dispatch()
        #expect(await rig.taps() == 0)
    }

    // MARK: (f) Verification decides whether the step advances

    @Test func testAVerifiedStepAdvancesToTheNextStep() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        await rig.driver.queueNextSnapshot(Self.screen("snap_1", selected: "second"))
        let result = await rig.dispatch()
        guard case .success(let verification) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(verification.verified)
        #expect(rig.controller.currentStepIndex == 1)
        #expect(rig.controller.completedStepCount == 1)
        #expect(await rig.taps() == 1)
    }

    @Test func testAnUnverifiedStepDoesNotAdvance() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        await rig.driver.queueNextSnapshot(Self.screen("snap_1", selected: "first"))   // the tab never changed
        let result = await rig.dispatch()
        guard case .success(let verification) = result else { Issue.record("expected a verification result, got \(result)"); return }
        #expect(!verification.verified)
        #expect(rig.controller.currentStepIndex == 0)
        #expect(rig.controller.completedStepCount == 0)
        #expect(rig.controller.consecutiveFailures >= 1, "an unverified step counts as a failure")
    }

    @Test func testAMutatingStepWithNoVerificationRuleIsNeverVerified() async throws {
        let rig = Rig()
        let bare = ScenarioStep(id: "s1", name: "tap second", description: "d", toolName: "tap_element", locator: ScenarioLocator(role: "button", label: "Second"))
        let scenario = SafeScenario(id: "BARE", name: "bare", purpose: "p", initialStateRequirement: "", expectedPostActionState: "", changesUIState: true, actionStep: bare)
        let catalog = ScenarioCatalog(scenarios: [scenario])
        let controller = ScenarioExecutionController(catalog: catalog, validator: TrustedActionValidator(catalog: catalog))
        controller.clock = rig.clock
        _ = controller.startScenario(scenario)
        controller.recordObservation(rig.start)
        let proposal = ActionProposal(scenarioID: "BARE", snapshotID: rig.start.snapshotID, elementID: "e3", expectedRole: "button", expectedIdentifier: "Second",
                                      toolName: "tap_element", reason: "r", stepIndex: 0, stepID: "s1")
        guard case .success = controller.handleProposal(proposal) else { Issue.record("expected the proposal to be accepted"); return }
        controller.approveCurrentStep(source: .testAuthority)
        await rig.driver.queueNextSnapshot(Self.screen("snap_1", selected: "second"))   // the screen did change, but nothing says what to expect
        let result = await controller.dispatchCurrentStep(driver: rig.driver, toolRegistry: rig.registry, bundleID: Self.bundle, isLive: false)
        guard case .success(let verification) = result else { Issue.record("expected a verification result"); return }
        #expect(!verification.verified, "a step that declares no check cannot be called verified")
        #expect(!controller.isCompleted)
        #expect(controller.completedStepCount == 0)
    }

    @Test func testAfterAVerifiedStepOnlyTheNextStepCanBeProposed() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        let after = Self.screen("snap_1", selected: "second")
        await rig.driver.queueNextSnapshot(after)
        _ = await rig.dispatch()
        rig.controller.recordObservation(after)
        // Repeating step 1 is refused; step 2 is accepted.
        guard case .failure = rig.propose(rig.proposal()) else { Issue.record("replaying step 1 must be refused"); return }
        guard case .success = rig.propose(rig.proposal(element: "e2", identifier: "tab.first", stepIndex: 1, stepID: "s2")) else {
            Issue.record("step 2 should be accepted"); return
        }
    }

    @Test func testAWholeScenarioRunsStepByStepThroughTheSpine() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        let second = Self.screen("snap_1", selected: "second")
        await rig.driver.queueNextSnapshot(second)
        _ = await rig.dispatch()
        rig.controller.recordObservation(second)
        await rig.driver.setSnapshot(second)   // the simulated device now shows what step 1 produced
        _ = try rig.propose(rig.proposal(element: "e2", identifier: "tab.first", stepIndex: 1, stepID: "s2")).get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        await rig.driver.queueNextSnapshot(Self.screen("snap_2", selected: "first"))
        let result = await rig.dispatch()
        guard case .success(let verification) = result, verification.verified else { Issue.record("step 2 should verify, got \(result)"); return }
        #expect(rig.controller.isCompleted)
        #expect(await rig.taps() == 2)
    }

    // MARK: Pause, cancel

    @Test func testAPausedControllerNeitherAcceptsNorDispatches() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        rig.controller.isPaused = true
        _ = await rig.dispatch()
        #expect(await rig.taps() == 0)
        guard case .failure = rig.propose(rig.proposal(snapshot: "snap_0")) else { Issue.record("a paused controller accepts no proposals"); return }
    }

    @Test func testACancelledScenarioDispatchesNothing() async throws {
        let rig = Rig()
        _ = try rig.propose().get()
        rig.controller.approveCurrentStep(source: .testAuthority)
        rig.controller.cancel(reason: "stop")
        _ = await rig.dispatch()
        #expect(await rig.taps() == 0)
    }
}
