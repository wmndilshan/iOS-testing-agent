import Foundation

// Container-scoped semantic interactions. Each resolves its target against the driver's trusted latest snapshot and acts
// through one known XCUIElement API inside the typed runner (navigation bar button, tab bar button, the Return key).

extension BackAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.navigateBack(snapshotID: target.snapshotID, elementID: target.elementID))
    }
}

extension SelectTabAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.selectTab(snapshotID: target.snapshotID, elementID: target.elementID))
    }
}

extension DismissKeyboardAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.dismissKeyboard(snapshotID: target.snapshotID, elementID: target.elementID))
    }
}
