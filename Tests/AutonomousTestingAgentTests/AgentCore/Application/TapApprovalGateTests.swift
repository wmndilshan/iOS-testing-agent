import Foundation
import Testing
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Tap execution through the registry")
struct TapApprovalGateTests {
    @Test func testMockDriverConfirmsActionWasActuallyInvoked() async throws {
        let config = try Configuration.load()
        let mockDriver = SimulatedDriver()
        let registry = ToolRegistry(projectRoot: config.projectRoot, driver: mockDriver)

        let call = ToolCall(id: "call_verify_invoke", name: "tap_element", arguments: [
            "snapshotID": .string("snap_mock_1"),
            "elementID": .string("elem_3")
        ])

        let result = try await registry.execute(call, authorization: AuthorizationFixture.authorized(for: call))
        #expect(result.status == .success)

        // Verify driver actually invoked the action
        let tapCount = await mockDriver.invokedActionCount["tap"] ?? 0
        let captured = await mockDriver.capturedActions
        #expect(tapCount == 1)
        #expect(captured.contains("tap(elem_3)"))
    }

}
