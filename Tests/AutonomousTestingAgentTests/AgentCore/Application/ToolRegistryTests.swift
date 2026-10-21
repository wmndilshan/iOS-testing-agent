import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import AgentEngine

@Test func testToolRegistryGetProjectInfo() async throws {
    let config = try Configuration.load()
    let registry = ToolRegistry(projectRoot: config.projectRoot, driver: SimulatedDriver())
    let info = registry.getProjectInfo()

    #expect(info.projectName == "AutonomousTestingAgent")
    #expect(info.packageSwiftPresent == true)
    #expect(!info.sourceFiles.isEmpty)
    #expect(info.projectStructure.contains("Sources/"))

    // Test execute method
    let call = ToolCall(id: "c1", name: "get_project_info", arguments: [:])
    let dict = try await registry.executeReadOnly(toolCall: call).payload
    #expect(dict?["projectName"] == .string("AutonomousTestingAgent"))
    #expect(dict?["packageSwiftPresent"] == .bool(true))
}


@Test func testToolRegistryValidationValidTap() async throws {
    let mockDriver = SimulatedDriver()
    let config = try Configuration.load()
    let registry = ToolRegistry(projectRoot: config.projectRoot, driver: mockDriver)

    let call = ToolCall(id: "c1", name: "tap_element", arguments: [
        "snapshotID": .string("snap_mock_1"),
        "elementID": .string("elem_1")
    ])

    let result = try await registry.execute(call, authorization: AuthorizationFixture.authorized(for: call))
    #expect(result.status == .success)
    #expect(result.summary.contains("elem_1"))
}

@Test func testToolRegistryValidationMissingArguments() async throws {
    let mockDriver = SimulatedDriver()
    let config = try Configuration.load()
    let registry = ToolRegistry(projectRoot: config.projectRoot, driver: mockDriver)

    let invalidCall = ToolCall(id: "c2", name: "tap_element", arguments: [
        "snapshotID": .string("snap_mock_1")
        // Missing elementID
    ])

    await #expect(throws: ToolRegistryError.self) {
        _ = try await registry.execute(invalidCall, authorization: AuthorizationFixture.authorized(for: invalidCall))
    }
}

@Test func testToolRegistryValidationGestures() async throws {
    let mockDriver = SimulatedDriver()
    let config = try Configuration.load()
    let registry = ToolRegistry(projectRoot: config.projectRoot, driver: mockDriver)

    // Double tap
    let dtCall = ToolCall(id: "c_dt", name: "double_tap_element", arguments: [
        "snapshotID": .string("snap_mock_1"),
        "elementID": .string("elem_3")
    ])
    let dtRes = try await registry.execute(dtCall, authorization: AuthorizationFixture.authorized(for: dtCall))
    #expect(dtRes.status == .success)

    // Long press
    let lpCall = ToolCall(id: "c_lp", name: "long_press_element", arguments: [
        "snapshotID": .string("snap_mock_1"),
        "elementID": .string("elem_2"),
        "durationSeconds": .double(0.85)
    ])
    let lpRes = try await registry.execute(lpCall, authorization: AuthorizationFixture.authorized(for: lpCall))
    #expect(lpRes.status == .success)

    // Swipe
    let swCall = ToolCall(id: "c_sw", name: "swipe", arguments: [
        "snapshotID": .string("snap_mock_1"),
        "elementID": .string("elem_1"),
        "direction": .string("up")
    ])
    let swRes = try await registry.execute(swCall, authorization: AuthorizationFixture.authorized(for: swCall))
    #expect(swRes.status == .success)

    // Drag and drop
    let ddCall = ToolCall(id: "c_dd", name: "drag_and_drop", arguments: [
        "snapshotID": .string("snap_mock_1"),
        "sourceElementID": .string("elem_1"),
        "destinationElementID": .string("elem_2")
    ])
    let ddRes = try await registry.execute(ddCall, authorization: AuthorizationFixture.authorized(for: ddCall))
    #expect(ddRes.status == .success)
}

