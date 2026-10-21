import Foundation

// Typed text is sensitive: these performers never place it in a summary, payload, diagnostic or log.

extension TypeTextAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        var out = IOSActionOutput(try await env.driver.typeText(snapshotID: target.snapshotID, elementID: target.elementID, text: text))
        out.diagnostics["textLength"] = String(text.count)
        return out
    }
}

extension ClearTextAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.clearText(snapshotID: target.snapshotID, elementID: target.elementID))
    }
}
