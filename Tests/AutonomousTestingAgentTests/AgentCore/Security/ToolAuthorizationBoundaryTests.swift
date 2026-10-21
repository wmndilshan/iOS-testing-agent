import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// A model-generated tool call is input, never an authorization. These tests attack the
/// ToolRegistry boundary directly and through the controller; every attack must fail closed
/// without touching the driver.
@Suite("Tool authorization boundary")
@MainActor
struct ToolAuthorizationBoundaryTests {

    private func taps(_ h: RunHarness) async -> Int { await h.driver.invokedActionCount["tap"] ?? 0 }

    private func tapCall(_ h: RunHarness) async throws -> ToolCall {
        let obs = try await h.driver.captureObservation(bundleID: ProductFixtures.bundleID)
        return ToolCall(id: "model-call", name: "tap_element", arguments: [
            "snapshotID": .string(obs.snapshotID), "elementID": .string(ProductFixtures.dropdown.id),
        ])
    }

    // MARK: Static classification

    @Test func testEveryDeclaredToolIsClassifiedAndSetsAreDisjoint() {
        for descriptor in ToolCatalog.descriptors {
            #expect(ToolCatalog.risk(of: descriptor.name) != nil, "'\(descriptor.name)' has no trusted classification")
        }
        #expect(ToolCatalog.readOnlyTools.isDisjoint(with: ToolCatalog.mutatingTools))
        #expect(ToolCatalog.risk(of: "some_new_tool") == nil, "unknown tools are unclassified and therefore refused")
        for name in ["tap_element", "type_text", "swipe", "scroll", "drag_and_drop"] {
            #expect(ToolCatalog.risk(of: name) == .mutating)
        }
        for name in ["get_accessibility_tree", "capture_screenshot", "get_app_state"] {
            #expect(ToolCatalog.risk(of: name) == .readOnly)
        }
    }

    // MARK: A model-generated call cannot execute by itself

    @Test func testModelGeneratedMutatingCallIsRefusedAndNeverReachesTheDriver() async throws {
        let h = RunHarness()
        let call = try await tapCall(h)
        await #expect(throws: ToolRegistryError.authorizationRequired("tap_element")) {
            _ = try await h.registry.executeReadOnly(toolCall: call)
        }
        #expect(await taps(h) == 0)
    }

    @Test func testCallCannotDeclareItselfReadOnly() async throws {
        let h = RunHarness()
        var call = try await tapCall(h)
        call = ToolCall(id: call.id, name: call.name, arguments: call.arguments.merging([
            "readOnly": .bool(true), "isReadOnly": .bool(true), "requiresApproval": .bool(false),
        ]) { $1 })
        await #expect(throws: ToolRegistryError.authorizationRequired("tap_element")) {
            _ = try await h.registry.executeReadOnly(toolCall: call)
        }
        #expect(await taps(h) == 0)
    }

    @Test func testUnknownToolIsRefusedByBothEntryPoints() async {
        let h = RunHarness()
        let call = ToolCall(id: "x", name: "delete_everything", arguments: [:])
        await #expect(throws: ToolRegistryError.toolNotFound("delete_everything")) {
            _ = try await h.registry.executeReadOnly(toolCall: call)
        }
        await #expect(throws: ToolRegistryError.toolNotFound("delete_everything")) {
            _ = try await h.registry.execute(call, authorization: AuthorizationFixture.authorized(for: call))
        }
    }

    @Test func testReadOnlyObservationStillWorksWithoutAuthorization() async throws {
        let h = RunHarness()
        let call = ToolCall(id: "obs", name: "get_accessibility_tree", arguments: [:])
        let result = try await h.registry.executeReadOnly(toolCall: call)
        #expect(result.observation != nil)
    }


    // MARK: Authorization evidence must cover exactly this call

    @Test func testAuthorizationForAnotherToolOrDifferentArgumentsIsRejected() async throws {
        let h = RunHarness()
        let call = try await tapCall(h)
        let proofForSwipe = AuthorizationFixture.authorized(for: ToolCall(id: "p", name: "swipe", arguments: call.arguments))
        await #expect(throws: ToolRegistryError.authorizationMismatch("tap_element")) {
            _ = try await h.registry.execute(call, authorization: proofForSwipe)
        }
        var swapped = call.arguments
        swapped["elementID"] = .string("some_other_element")
        let proofForOtherTarget = AuthorizationFixture.authorized(for: ToolCall(id: "p", name: "tap_element", arguments: swapped))
        await #expect(throws: ToolRegistryError.authorizationMismatch("tap_element")) {
            _ = try await h.registry.execute(call, authorization: proofForOtherTarget)
        }
        #expect(await taps(h) == 0)
    }

    @Test func testMatchingAuthorizationExecutesExactlyThatCall() async throws {
        let h = RunHarness()
        let call = try await tapCall(h)
        _ = try await h.registry.execute(call, authorization: AuthorizationFixture.authorized(for: call))
        #expect(await taps(h) == 1)
    }

    // MARK: Missing, invalid, expired, wrong-snapshot, wrong-target authorization never produces a proof

    @Test func testAuthorizerRefusesToMintProofForBadApprovals() {
        let call = ToolCall(id: "c", name: "tap_element", arguments: [:])
        let step = AuthorizationFixture.step(for: call)
        let obs = AuthorizationFixture.observation
        let now = AuthorizationFixture.now
        func refused(_ a: HITLApprovalRequest?, obs o: Observation? = obs, at t: Date = now, step s: ScenarioStep? = nil) -> Bool {
            guard let a else { return true }   // missing approval: nothing to authorize
            if case .rejected = DispatchAuthorizer().authorize(approval: a, step: s ?? step, observation: o, now: t) { return true }
            return false
        }
        #expect(refused(nil))
        #expect(refused(AuthorizationFixture.approval(for: call, status: .pending)))
        #expect(refused(AuthorizationFixture.approval(for: call, status: .denied)))
        #expect(refused(AuthorizationFixture.approval(for: call, status: .succeeded)), "an already-consumed approval is not reusable")
        #expect(refused(AuthorizationFixture.approval(for: call, expiresIn: 10), at: now.addingTimeInterval(11)))
        #expect(refused(AuthorizationFixture.approval(for: call, snapshotID: "not-the-current-snapshot")))
        #expect(refused(AuthorizationFixture.approval(for: call), obs: nil))
        let otherToolStep = AuthorizationFixture.step(for: ToolCall(id: "c", name: "swipe", arguments: [:]))
        #expect(refused(AuthorizationFixture.approval(for: call), step: otherToolStep), "approved tool must equal the scenario step's tool")
    }

    // MARK: Through the trusted controller

    @Test func testProposalForAnotherScenarioIsRejected() async {
        let h = RunHarness()
        h.begin()
        let obs = ProductFixtures.observation("s0", [ProductFixtures.dropdown])
        h.controller.recordObservation(obs)
        let p = ActionProposal(scenarioID: "SOME-OTHER-SCENARIO", snapshotID: obs.snapshotID, elementID: ProductFixtures.dropdown.id,
                               expectedRole: "button", expectedIdentifier: ProductFixtures.dropdown.identifier,
                               toolName: "tap_element", reason: "attack")
        guard case .failure = h.controller.handleProposal(p) else { Issue.record("expected rejection"); return }
        #expect(h.controller.activeApproval == nil)
    }

    @Test func testDispatchWithoutApprovalNeverReachesTheDriver() async {
        let h = RunHarness()
        h.begin()
        h.controller.recordObservation(ProductFixtures.observation("s0", [ProductFixtures.dropdown]))
        let result = await h.controller.dispatchCurrentStep(driver: h.driver, toolRegistry: h.registry)
        guard case .failure = result else { Issue.record("expected failure"); return }
        #expect(await taps(h) == 0)
    }

    @Test func testConsumedAuthorizationCannotBeReplayed() async {
        let h = RunHarness()
        h.begin()
        let s0 = ProductFixtures.observation("s0", [ProductFixtures.dropdown])
        let s1 = ProductFixtures.observation("s1", [ProductFixtures.closeButton])
        guard case .success = await h.runStep(target: ProductFixtures.dropdown, before: s0, after: s1) else {
            Issue.record("first dispatch should succeed"); return
        }
        #expect(await taps(h) == 1)
        // The token is spent: dispatching again, with no new proposal and approval, must fail.
        let replay = await h.controller.dispatchCurrentStep(driver: h.driver, toolRegistry: h.registry)
        guard case .failure = replay else { Issue.record("replay must be rejected"); return }
        #expect(await taps(h) == 1, "no second tap")
    }
}
