import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Tool platform: catalog, schemas, resolver")
struct ToolPlatformTests {

    private let validator = ToolInputValidator()
    private func descriptor(_ name: String) -> ToolDescriptor { ToolCatalog.descriptor(for: name)! }

    @Test func testCatalogIsCompleteUniqueAndVersioned() {
        let names = ToolCatalog.descriptors.map(\.name)
        #expect(names.count == 18 && Set(names).count == names.count, "unique tool names")
        #expect(ToolCatalog.descriptors.allSatisfy { $0.version >= 1 && !$0.summary.isEmpty })
        #expect(ToolCatalog.readOnlyTools.isDisjoint(with: ToolCatalog.mutatingTools))
        #expect(ToolCatalog.readOnlyTools.union(ToolCatalog.mutatingTools) == Set(names))
    }

    @Test func testMutatingToolsRequireApprovalAndReadOnlyToolsDoNot() {
        for d in ToolCatalog.descriptors { #expect(d.requiresApproval == (d.risk == .mutating), "\(d.name)") }
        #expect(descriptor("tap_element").category == .interaction && descriptor("tap_element").platform == .ios)
        #expect(descriptor("get_project_info").platform == .host && descriptor("get_project_info").risk == .readOnly)
        #expect(descriptor("capture_screenshot").category == .capture)
    }

    @Test func testSchemaRejectsUnknownFieldsMissingFieldsAndWrongTypes() {
        let tap = descriptor("tap_element")
        #expect(validator.violation(of: tap, arguments: ["snapshotID": "s", "elementID": "e"]) == nil)
        #expect(validator.violation(of: tap, arguments: ["snapshotID": "s", "elementID": "e", "x": "y"])?.contains("does not accept field 'x'") == true)
        #expect(validator.violation(of: tap, arguments: ["snapshotID": "s"])?.contains("requires 'elementID'") == true)
        #expect(validator.violation(of: tap, arguments: ["snapshotID": "s", "elementID": .int(3)])?.contains("must be string") == true)
        let wait = descriptor("wait_for_element")
        #expect(validator.violation(of: wait, arguments: ["identifier": "i", "timeoutSeconds": .int(5)]) == nil, "numbers accept ints and doubles")
        #expect(validator.violation(of: wait, arguments: ["identifier": "i", "timeoutSeconds": "5"]) != nil)
    }

    @Test func testEnumeratedFieldsRejectValuesOutsideTheAllowedSet() {
        let swipe = descriptor("swipe")
        #expect(validator.violation(of: swipe, arguments: ["snapshotID": "s", "elementID": "e", "direction": "UP"]) == nil)
        #expect(validator.violation(of: swipe, arguments: ["snapshotID": "s", "elementID": "e", "direction": "diagonal"]) != nil)
    }

    @Test func testResolverRefusesUnknownToolsAndInvalidInput() {
        #expect(throws: ToolRegistryError.toolNotFound("rm_rf")) { _ = try ToolResolver().resolve(ToolCall(id: "1", name: "rm_rf", arguments: [:])) }
        #expect(throws: ToolRegistryError.self) { _ = try ToolResolver().resolve(ToolCall(id: "1", name: "tap_element", arguments: ["elementID": "e"])) }
        let ok = try? ToolResolver().resolve(ToolCall(id: "1", name: "tap_element", arguments: ["snapshotID": "s", "elementID": "e"]))
        #expect(ok?.descriptor.name == "tap_element")
    }

    @Test func testRegistryRejectsUnknownFieldsAtExecutionEvenWithAValidProof() async throws {
        let h = await RunHarness()
        let call = ToolCall(id: "c", name: "tap_element", arguments: ["snapshotID": "s", "elementID": "e", "smuggled": "value"])
        await #expect(throws: ToolRegistryError.self) {
            _ = try await h.registry.execute(call, authorization: AuthorizationFixture.authorized(for: call))
        }
        let taps = await h.driver.invokedActionCount["tap"] ?? 0
        #expect(taps == 0)
    }

    @Test @MainActor func testAdmissionDropsUnknownFieldsAndRejectsMissingRequiredOnesBeforeApproval() {
        let scenario = ScenarioCatalog.shared.findScenario(by: "SCENARIO-LANG-SHEET")!
        let obs = ProductFixtures.observation("adm", [ProductFixtures.dropdown])
        let proposal = ActionProposal(scenarioID: scenario.id, snapshotID: obs.snapshotID, elementID: ProductFixtures.dropdown.id,
                                      expectedRole: "button", expectedIdentifier: ProductFixtures.dropdown.identifier,
                                      toolName: "tap_element", arguments: ["note": "hello", "duration": 3], reason: "t", stepIndex: 0)
        let verdict = ProposalAdmission(validator: TrustedActionValidator()).admit(
            proposal, step: scenario.steps[0], stepIndex: 0, observation: obs, existingApproval: nil, executedFingerprints: [], now: Date())
        guard case .accepted(let request) = verdict else { Issue.record("expected accepted"); return }
        #expect(Set(request.arguments.keys) == ["snapshotID", "elementID"], "undeclared fields never reach the approval")
    }

    @Test func testResultsCarryToolExecutionAndFailureDetail() async throws {
        let h = await RunHarness()
        let call = ToolCall(id: "obs", name: "get_accessibility_tree", arguments: [:])
        let result = try await h.registry.executeReadOnly(toolCall: call, executionID: "exec-1")
        #expect(result.toolName == "get_accessibility_tree" && result.executionID == "exec-1")
        #expect(result.durationSeconds != nil && result.failure == nil && result.artifacts.isEmpty)
    }

    @Test func testToolResultStaysBackwardCompatibleWithOlderJSON() throws {
        let old = #"{"callID":"c","status":"success","summary":"ok"}"#
        let r = try JSONDecoder().decode(ToolResult.self, from: Data(old.utf8))
        #expect(r.callID == "c" && r.toolName == nil && r.artifacts.isEmpty && r.failure == nil)
        let failed = ToolResult(callID: "c", status: .timedOut, summary: "slow", failure: ToolFailure(category: .timeout, retryable: true, message: "slow"))
        let back = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(failed))
        #expect(back == failed)
    }
}
