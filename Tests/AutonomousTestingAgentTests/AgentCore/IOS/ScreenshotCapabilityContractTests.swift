import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// The contract the `screenshot` capability must keep to be admissible as evidence (Phase 20).
///
/// These are unit and integration tests over the typed path and the trusted catalog; none of them performs or
/// simulates a live run, and none of them may be cited as live evidence. The live evidence is the recorded execution
/// by a recorded live run, which these tests only cross-check for honesty.
@Suite("Screenshot capability contract")
struct ScreenshotCapabilityContractTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    private func store() -> (FileArtifactStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shot-contract-\(UUID().uuidString)")
        return (FileArtifactStore(directory: dir), dir)
    }

    // MARK: A — read-only

    @Test func testTheScreenshotActionIsReadOnlyEverywhereItIsClassified() async throws {
        #expect(!IOSAction.screenshot(ScreenshotAction(reason: "r")).isMutating)
        #expect(ToolCatalog.risk(of: "capture_screenshot") == .readOnly)
        #expect(ToolCatalog.readOnlyTools.contains("capture_screenshot"))
        // The performer touches no mutating driver method: the driver records every action it is asked to perform.
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let driver = FileScreenshotDriver(screenshotBytes: png)
        _ = try await IOSTestSupport.executor(driver: driver, store: store)
            .execute(.screenshot(ScreenshotAction(reason: "r")), context: IOSActionContext(toolName: "capture_screenshot", executionID: "e"))
        let mutating = ["tap", "doubleTap", "longPress", "swipe", "scroll", "dragAndDrop", "typeText", "clearText", "launch", "terminate", "activate"]
        for action in await driver.base.capturedActions {
            #expect(!mutating.contains(where: action.hasPrefix), Comment(rawValue: "screenshot invoked \(action)"))
        }
    }


    @Test func testTheReadOnlyScenarioCannotSmuggleAMutatingTool() throws {
        let scenario = try #require(FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-SCREENSHOT"))
        #expect(!scenario.changesUIState && scenario.teardownStep == nil)
        #expect(scenario.actionStep.toolName == "capture_screenshot")
        let validator = TrustedActionValidator(catalog: FixtureScenarioCatalog.shared)
        let observation = ProductFixtures.observation("snap_s", [ProductFixtures.element("elem_1", role: "button", identifier: "fixture.tap.target", label: "Tap target")])
        func propose(_ tool: String) -> TrustedValidationResult {
            validator.validate(
                proposal: ActionProposal(scenarioID: "FIXTURE-SCREENSHOT", snapshotID: observation.snapshotID, elementID: "elem_1", expectedRole: "button",
                                         expectedIdentifier: "fixture.tap.target", toolName: tool, arguments: [:], reason: "test",
                                         stepIndex: 0, stepID: "step_fixture_screenshot"),
                activeObservation: observation, activeStep: scenario.actionStep, activeStepIndex: 0)
        }
        for mutating in ["tap_element", "type_text", "scroll", "navigate_back", "drag_and_drop"] {
            let result = propose(mutating)
            #expect(result.isValid == false, Comment(rawValue: "\(mutating) was admitted into a read-only scenario"))
            #expect(result.rejectionReason?.contains("read-only") == true)
        }
        #expect(propose("capture_screenshot").isValid)
    }

    // MARK: B, H — the artifact belongs to this execution

    @Test func testTheStoredArtifactCarriesTheExecutionThatProducedIt() async throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let executor = IOSTestSupport.executor(driver: FileScreenshotDriver(screenshotBytes: png), store: store)
        let context = IOSActionContext(toolName: "capture_screenshot", executionID: "EXEC-1",
                                       association: ArtifactAssociation(runID: "RUN-1", scenarioID: "FIXTURE-SCREENSHOT", stepID: "step_fixture_screenshot"))
        let exec = try await executor.execute(.screenshot(ScreenshotAction(reason: "evidence")), context: context)
        let ref = try #require(exec.result.evidence.first)
        let stored = try await store.artifact(id: ref.id)
        #expect(stored.metadata["executionID"] == "EXEC-1", "the artifact names its execution")
        #expect(stored.metadata["toolName"] == "capture_screenshot")
        #expect(stored.association.runID == "RUN-1" && stored.association.stepID == "step_fixture_screenshot")
        #expect(exec.result.executionID == "EXEC-1")
        #expect(stored.checksum == IntegrityHash.sha256Hex(png) && stored.byteCount == png.count)
    }

    @Test func testAnArtifactFromAnotherExecutionIsDistinguishableAndNeverAttributedToThisOne() async throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let executor = IOSTestSupport.executor(driver: FileScreenshotDriver(screenshotBytes: png), store: store)
        for (execution, run) in [("EXEC-A", "RUN-A"), ("EXEC-B", "RUN-B")] {
            _ = try await executor.execute(.screenshot(ScreenshotAction(reason: "r")),
                                           context: IOSActionContext(toolName: "capture_screenshot", executionID: execution,
                                                                     association: ArtifactAssociation(runID: run, scenarioID: "S", stepID: "st")))
        }
        let a = await store.artifacts(runID: "RUN-A")
        let b = await store.artifacts(runID: "RUN-B")
        #expect(a.count == 1 && b.count == 1)
        #expect(a[0].metadata["executionID"] == "EXEC-A" && b[0].metadata["executionID"] == "EXEC-B")
        #expect(a[0].id != b[0].id, "two executions never share one artifact identity")
    }

    // MARK: C, K — invalid captures fail closed, in the existing taxonomy

    @Test func testAnEmptyOrMissingImageFailsClosedAsAnObservationFailure() async {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        for bytes in [nil, Data()] as [Data?] {
            let executor = IOSTestSupport.executor(driver: FileScreenshotDriver(screenshotBytes: bytes), store: store)
            do {
                _ = try await executor.execute(.screenshot(ScreenshotAction(reason: "r")), context: IOSActionContext(executionID: "e"))
                Issue.record("an empty capture must not be reported as success")
            } catch {
                #expect(ActionFailureKind.of(error) == .observationFailed)
            }
        }
        // Nothing was written for a failed capture.
        #expect(await store.artifacts(scenarioID: "S").isEmpty)
    }


    // MARK: Stale observation


    // MARK: D, E, F, G — identity and provenance refusals are the existing ones



    // MARK: I, J — evidence honesty and no host paths

    @Test func testAStoredArtifactNeverCarriesAHostPath() async throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let driver = FileScreenshotDriver(screenshotBytes: png)
        let exec = try await IOSTestSupport.executor(driver: driver, store: store)
            .execute(.screenshot(ScreenshotAction(reason: "r")), context: IOSActionContext(toolName: "capture_screenshot", executionID: "e"))
        let ref = try #require(exec.result.evidence.first)
        let stored = try await store.artifact(id: ref.id)
        let encoded = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        for leak in ["/Users/", "/private/", "/var/folders", ".png"] {
            #expect(!encoded.contains(leak), Comment(rawValue: "artifact record leaks \(leak)"))
        }
        #expect(exec.output.payload?["screenshotPath"] == nil, "no filesystem path travels in the result")
        #expect(!exec.output.summary.contains(driver.screenshotURL?.path ?? "//"))
    }

}
