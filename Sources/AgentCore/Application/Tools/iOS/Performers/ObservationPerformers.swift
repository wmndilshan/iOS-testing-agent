import Foundation

// Observation capabilities. One observation model (`Observation`) is produced by the driver; nothing here
// parses accessibility data itself.

extension AccessibilityTreeAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        env.logger.debug(.observation, "ios.observation.started", context: env.context, fields: ["actionType": "accessibility_tree"])
        let obs = try await env.driver.captureObservation(bundleID: bundleID)
        env.logger.info(.observation, "ios.observation.completed", context: env.context.merged(with: LogContext(snapshotID: obs.snapshotID)),
                        fields: ["elementCount": .int(obs.elements.count), "truncated": .bool(obs.isTruncated)])
        let truncText = obs.isTruncated ? " (tree was truncated to bounds)" : ""
        return IOSActionOutput(summary: "Captured accessibility tree with \(obs.elements.count) elements\(truncText).", observation: obs)
    }
}

extension AppStateAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        let obs = try await env.driver.captureObservation(bundleID: bundleID)
        return IOSActionOutput(summary: "Application '\(bundleID)' state: \(obs.appState.rawValue).", observation: obs)
    }
}

extension ElementDetailsAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        IOSActionOutput(try await env.driver.getElementDetails(snapshotID: target.snapshotID, elementID: target.elementID))
    }
}

extension InspectElementsAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        // Expectations come only from the trusted scenario selected by the controller. The prior fixed login-screen
        // lookup made an otherwise generic read-only capability reject every authorized non-login surface.
        let expected = env.context.scenarioID.flatMap { scenarioID in
            FixtureScenarioCatalog.shared.findScenario(by: scenarioID)?.expectedElements
                ?? ScenarioCatalog.shared.findScenario(by: scenarioID)?.expectedElements
        } ?? []
        return IOSActionOutput(try await env.driver.inspectElements(snapshotID: snapshotID, expectedElements: expected))
    }
}

/// Waits by polling *fresh observations* through the one bounded `ConditionWaiter`. It does not depend on a
/// driver-specific wait, so simulation and live behave the same way: the element is either observed or the
/// wait times out. (In live mode each poll is a real accessibility observation, so wall-clock time can exceed the
/// requested timeout; the number of polls is capped.)
extension WaitForElementAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        var lastObservation: Observation?
        let outcome = try await ConditionWaiter(clock: env.clock).wait(timeout: timeoutSeconds, pollInterval: pollIntervalSeconds) {
            let obs = try await env.driver.captureObservation(bundleID: env.bundleID)
            lastObservation = obs
            return obs.elements.contains { $0.identifier == identifier }
        }
        guard outcome.satisfied else {
            throw DriverError.timedOut("wait_for_element '\(identifier)' not observed after \(outcome.polls) polls (\(timeoutSeconds)s budget)")
        }
        return IOSActionOutput(
            summary: "Element with identifier '\(identifier)' was observed after \(outcome.polls) poll(s).",
            observation: lastObservation, diagnostics: ["polls": String(outcome.polls)])
    }
}

/// Screenshots are stored as artifacts and returned as references, never as bytes. Without an artifact store
/// (tests, previews) the driver's file path is returned as before.
extension ScreenshotAction: IOSPerformable {
    func perform(in env: IOSExecutionEnvironment) async throws -> IOSActionOutput {
        let (path, obs) = try await env.driver.captureScreenshot(reason: reason)
        guard let store = env.artifactStore else {
            return IOSActionOutput(summary: "Captured visual screenshot evidence at '\(path)': \(reason).", payload: ["screenshotPath": .string(path)], observation: obs)
        }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), !bytes.isEmpty else {
            throw DriverError.observationFailed("Screenshot was requested but no image file was produced.")
        }
        // Same provenance convention as other run evidence: the execution that produced the capture is stamped on the
        // artifact, so a stored screenshot can never be re-attributed to another execution.
        let artifact = try await store.save(bytes, kind: .screenshot, source: "simulator", association: env.association,
                                            metadata: ["reason": reason,
                                                       "executionID": env.context.executionID ?? "",
                                                       "toolName": env.context.toolName ?? "capture_screenshot"])
        return IOSActionOutput(
            summary: "Captured screenshot artifact \(artifact.id) (\(artifact.byteCount) bytes): \(reason).",
            payload: ["artifactID": .string(artifact.id), "checksum": .string(artifact.checksum), "byteCount": .int(artifact.byteCount)],
            observation: obs, evidence: [artifact.artifactReference])
    }
}
