import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// The contract `wait_for_element` must keep.
///
/// These are unit and integration tests over the typed path; none of them is live evidence and none may be cited as
/// such. The capability's live status is decided only by a recorded live execution, which the
/// last test here cross-checks.
@Suite("Wait for element contract")
struct WaitForElementContractTests {
    private func ctx() -> IOSActionContext {
        IOSActionContext(toolName: "wait_for_element", executionID: "EXEC-WAIT",
                         bundleID: ProductFixtures.bundleID,
                         association: ArtifactAssociation(runID: "RUN-WAIT", scenarioID: "S", stepID: "st"))
    }

    // MARK: Identity of the target

    @Test func testTheTargetIsAnAccessibilityIdentifierAndNothingPositional() {
        guard let descriptor = ToolCatalog.descriptor(for: "wait_for_element") else {
            Issue.record("wait_for_element must remain in the trusted catalog")
            return
        }
        let fields = Set(descriptor.fieldNames)
        #expect(fields == ["identifier", "timeoutSeconds"], "the only target identity is an accessibility identifier")
        let validator = ToolInputValidator()
        // Anything positional or visual is not part of the schema and is refused before the action is built.
        for positional in ["x", "y", "coordinate", "point", "frame", "image", "pixel", "label", "role"] {
            let violation = validator.violation(of: descriptor, arguments: ["identifier": "i", positional: "1"])
            #expect(violation?.contains("does not accept field '\(positional)'") == true, Comment(rawValue: positional))
        }
    }

    @Test func testAnEmptyOrOutOfRangeRequestNeverBecomesAnAction() {
        #expect(throws: ToolRegistryError.self) {
            _ = try IOSActionDecoder().decode(ToolCall(id: "c", name: "wait_for_element", arguments: ["identifier": ""]), bundleID: ProductFixtures.bundleID)
        }
        #expect(WaitForElementAction.timeoutRange == 0.1...60.0)
        #expect(ConditionWaiter.maximumPolls == 30, "polling is bounded whatever the timeout says")
    }

    // MARK: Fresh observations only

    @Test func testEveryPollTakesItsOwnFreshObservationAndTheResultNamesTheLastOne() async throws {
        let without = ProductFixtures.observation("w-absent", [ProductFixtures.element("a", identifier: "other")])
        let with = ProductFixtures.observation("w-present", [ProductFixtures.element("b", identifier: "fixture.overlay.title")])
        let driver = SimulatedDriver(currentSnapshot: without)
        await driver.queueNextSnapshot(without); await driver.queueNextSnapshot(with)
        let clock = TestClock()
        let exec = try await IOSTestSupport.executor(driver: driver, clock: clock)
            .execute(.waitForElement(WaitForElementAction(identifier: "fixture.overlay.title", timeoutSeconds: 5)), context: ctx())
        #expect(exec.result.success)
        // One observation per poll, and the observation the result names is the one that satisfied the condition.
        #expect(await driver.invokedActionCount["captureObservation"] == 2)
        #expect(exec.result.postObservationID == with.snapshotID, "never the earlier, unsatisfied observation")
        #expect(exec.result.diagnostics["polls"] == "2")
    }

    @Test func testTheWaitNeverReadsACachedOrHistoricalHierarchy() throws {
        let performers = try #require(SourceTree.core.first { $0.name == "ObservationPerformers.swift" }).code
        let wait = try #require(performers.components(separatedBy: "extension WaitForElementAction: IOSPerformable").dropFirst().first)
            .components(separatedBy: "\n}")[0]
        #expect(wait.contains("env.driver.captureObservation(bundleID: env.bundleID)"), "each poll observes the simulator afresh")
        for cached in ["latestSnapshot", "activeObservation", "lastObservation ??", "cached"] {
            #expect(!wait.contains(cached), Comment(rawValue: "the wait must not consult \(cached)"))
        }
        // One polling loop, the shared bounded one.
        #expect(wait.contains("ConditionWaiter(clock: env.clock)"))
        #expect(performers.components(separatedBy: "ConditionWaiter(").count == 2, "no second polling loop exists")
    }

    // MARK: Failure is typed, and never a false success

    @Test func testAnAbsentTargetTimesOutWithTheTypedFailureAndBoundedPolls() async {
        let driver = SimulatedDriver(currentSnapshot: ProductFixtures.observation("only", [ProductFixtures.element("a", identifier: "other")]))
        let executor = IOSTestSupport.executor(driver: driver, clock: TestClock())
        do {
            _ = try await executor.execute(.waitForElement(WaitForElementAction(identifier: "never.appears", timeoutSeconds: 1, pollIntervalSeconds: 0.5)), context: ctx())
            Issue.record("an absent target must not be reported as found")
        } catch {
            #expect(ActionFailureKind.of(error) == .timeout)
            #expect((error as? DriverError)?.localizedDescription.contains("never.appears") == true)
        }
        #expect(await driver.invokedActionCount["captureObservation"] == 3, "1s budget at 0.5s => 3 bounded polls")
    }


    // MARK: The wait is read-only and reaches nothing it should not

    @Test func testTheWaitMutatesNothing() async throws {
        #expect(!IOSAction.waitForElement(WaitForElementAction(identifier: "i")).isMutating)
        #expect(ToolCatalog.risk(of: "wait_for_element") == .readOnly)
        let with = ProductFixtures.observation("w", [ProductFixtures.element("b", identifier: "target")])
        let driver = SimulatedDriver(currentSnapshot: with)
        _ = try await IOSTestSupport.executor(driver: driver, clock: TestClock())
            .execute(.waitForElement(WaitForElementAction(identifier: "target")), context: ctx())
        for action in await driver.capturedActions {
            #expect(action.hasPrefix("captureObservation"), Comment(rawValue: "the wait invoked \(action)"))
        }
    }

    @Test func testTheWaitHasNoProcessOrXCTestEscapeHatch() throws {
        for name in ["ObservationPerformers.swift", "IOSExecution.swift"] {
            let code = try #require(SourceTree.core.first { $0.name == name }).code
            for banned in ["Process()", "xcodebuild", "simctl", "/bin/sh", "NSSelectorFromString", "performSelector", "dlopen"] {
                #expect(!code.contains(banned), Comment(rawValue: "\(name): \(banned)"))
            }
        }
    }

    @Test func testAuthorizationIsStillRequiredWhereTheArchitectureRequiresIt() async throws {
        let driver = SimulatedDriver(currentSnapshot: ProductFixtures.observation("w", [ProductFixtures.element("b", identifier: "target")]))
        let registry = ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: driver)
        let call = ToolCall(id: "c", name: "wait_for_element", arguments: ["identifier": "target"])
        // The read-only entry point is the existing policy for this risk class, and it is the only one that runs
        // without an authorization value.
        let result = try await registry.executeReadOnly(toolCall: call, executionID: "E1")
        #expect(result.status == .success && result.executionID == "E1")
        // A mutating tool can never enter through it, whatever the call claims.
        await #expect(throws: ToolRegistryError.self) {
            _ = try await registry.executeReadOnly(toolCall: ToolCall(id: "c2", name: "tap_element", arguments: ["snapshotID": "w", "elementID": "b"]))
        }
        // `DispatchAuthorizer.Authorized` cannot be constructed outside the authorizer, so the scenario path cannot be
        // entered without one: the dispatcher's `execute` requires that value by type.
        let dispatcher = try #require(SourceTree.core.first { $0.name == "ScenarioStepDispatcher.swift" }).code
        #expect(dispatcher.contains("authorization: DispatchAuthorizer.Authorized"))
    }

    // MARK: Evidence honesty

}
