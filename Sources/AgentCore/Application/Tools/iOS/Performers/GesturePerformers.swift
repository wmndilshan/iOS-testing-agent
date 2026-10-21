import Foundation

extension SwipeAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.swipe(snapshotID: target.snapshotID, elementID: target.elementID, direction: direction))
    }
}

extension ScrollAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.scroll(snapshotID: snapshotID, containerID: containerID, direction: direction, velocity: velocity))
    }
}

extension DragAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.dragAndDrop(
            snapshotID: snapshotID, sourceElementID: sourceElementID,
            destinationElementID: destinationElementID, holdDurationSeconds: holdDurationSeconds))
    }
}
