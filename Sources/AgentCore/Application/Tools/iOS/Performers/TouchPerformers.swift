import Foundation

// Touch capabilities delegate to the driver port, which resolves the target against its trusted latest
// snapshot and throws typed `DriverError`s (stale snapshot, not found, not hittable, disabled).

extension TapAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.tap(snapshotID: target.snapshotID, elementID: target.elementID))
    }
}

extension DoubleTapAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.doubleTap(snapshotID: target.snapshotID, elementID: target.elementID))
    }
}

extension LongPressAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.longPress(snapshotID: target.snapshotID, elementID: target.elementID, durationSeconds: durationSeconds))
    }
}
