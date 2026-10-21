import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("iOS interaction executor")
struct IOSInteractionExecutorTests {

    private func setup(_ obs: Observation = IOSTestSupport.snapshot()) -> (SimulatedDriver, IOSInteractionExecutor, Observation) {
        let driver = SimulatedDriver(currentSnapshot: obs)
        return (driver, IOSTestSupport.executor(driver: driver), obs)
    }
    private func ctx(_ tool: String = "tool", exec: String = "exec-1") -> IOSActionContext { IOSActionContext(toolName: tool, executionID: exec) }

    @Test func testTapPerformsTheGestureAndReturnsAStandardizedResult() async throws {
        let (driver, executor, obs) = setup()
        let r = try await executor.execute(.tap(TapAction(target: IOSTestSupport.target(obs, "ok"))), context: ctx("tap_element")).result
        #expect(r.success && r.failure == nil && r.actionType == "tap" && r.toolName == "tap_element" && r.executionID == "exec-1")
        #expect(r.finishedAt >= r.startedAt && r.duration >= 0)
        let taps = await driver.invokedActionCount["tap"] ?? 0
        #expect(taps == 1)
    }

    @Test func testEachImplementedGestureReachesItsDriverMethodExactlyOnce() async throws {
        let (driver, executor, obs) = setup()
        let t = { IOSTestSupport.target(obs, $0) }
        _ = try await executor.execute(.doubleTap(DoubleTapAction(target: t("ok"))), context: ctx())
        _ = try await executor.execute(.longPress(LongPressAction(target: t("ok"), durationSeconds: 1)), context: ctx())
        _ = try await executor.execute(.swipe(SwipeAction(target: t("list"), direction: .up)), context: ctx())
        _ = try await executor.execute(.scroll(ScrollAction(snapshotID: obs.snapshotID, containerID: "list", direction: .down)), context: ctx())
        _ = try await executor.execute(.drag(DragAction(snapshotID: obs.snapshotID, sourceElementID: "ok", destinationElementID: "list")), context: ctx())
        _ = try await executor.execute(.typeText(TypeTextAction(target: t("field"), text: "hello")), context: ctx())
        _ = try await executor.execute(.clearText(ClearTextAction(target: t("field"))), context: ctx())
        for key in ["doubleTap", "longPress", "swipe", "scroll", "dragAndDrop", "typeText", "clearText"] {
            let n = await driver.invokedActionCount[key] ?? 0
            #expect(n == 1, "\(key)")
        }
    }

    @Test func testSemanticNavigationActionsReachTheirOwnDriverMethodExactlyOnce() async throws {
        let (driver, executor, obs) = setup()
        let t = { IOSTestSupport.target(obs, $0) }
        _ = try await executor.execute(.back(BackAction(target: t("ok"))), context: ctx("navigate_back"))
        _ = try await executor.execute(.selectTab(SelectTabAction(target: t("ok"))), context: ctx("select_tab"))
        _ = try await executor.execute(.dismissKeyboard(DismissKeyboardAction(target: t("field"))), context: ctx("dismiss_keyboard"))
        for key in ["navigateBack", "selectTab", "dismissKeyboard"] {
            let n = await driver.invokedActionCount[key] ?? 0
            #expect(n == 1, "\(key)")
        }
        let taps = await driver.invokedActionCount["tap"] ?? 0
        #expect(taps == 0, "semantic actions are never silently rewritten into generic taps")
    }

    @Test func testSemanticNavigationActionsRejectStaleSnapshotsAndUnknownElementsWithoutTouchingAnything() async {
        let (driver, executor, obs) = setup()
        let stale = ElementTarget(snapshotID: "old-snapshot", elementID: "ok")
        let missing = ElementTarget(snapshotID: obs.snapshotID, elementID: "no-such-element")
        for target in [stale, missing] {
            for action in [IOSAction.back(BackAction(target: target)), .selectTab(SelectTabAction(target: target)), .dismissKeyboard(DismissKeyboardAction(target: target))] {
                do { _ = try await executor.execute(action, context: ctx()); Issue.record("\(action.actionType) must refuse \(target.elementID)") }
                catch { #expect([.staleSnapshot, .targetNotFound].contains(ActionFailureKind.of(error)), "\(action.actionType): \(error)") }
            }
        }
        let captured = await driver.capturedActions
        #expect(captured.isEmpty)
    }

    @Test func testSemanticNavigationActionsFailClosedOnADriverWithoutTheCapability() async {
        let obs = IOSTestSupport.snapshot()
        let executor = IOSTestSupport.executor(driver: FileScreenshotDriver(base: SimulatedDriver(currentSnapshot: obs), screenshotBytes: nil))
        let t = IOSTestSupport.target(obs, "ok")
        for action in [IOSAction.back(BackAction(target: t)), .selectTab(SelectTabAction(target: t)), .dismissKeyboard(DismissKeyboardAction(target: t))] {
            do { _ = try await executor.execute(action, context: ctx()); Issue.record("\(action.actionType) must fail closed") }
            catch { #expect(ActionFailureKind.of(error) == .unsupportedCapability, "\(action.actionType): \(error)") }
        }
    }

    @Test func testTypedTextIsNotReturnedInResultsOrDiagnostics() async throws {
        let (_, executor, obs) = setup()
        let exec = try await executor.execute(.typeText(TypeTextAction(target: IOSTestSupport.target(obs, "field"), text: "TYPED-SECRET-123")), context: ctx())
        let blob = "\(exec.result)\(exec.output.summary)\(exec.output.diagnostics)\(exec.output.payload ?? [:])"
        #expect(!blob.contains("TYPED-SECRET-123"))
        #expect(exec.result.diagnostics["textLength"] == "16")
    }

    // MARK: Negative cases, per capability

    @Test func testStaleSnapshotIsRejectedForEveryTargetedAction() async {
        let (driver, executor, _) = setup()
        let stale = ElementTarget(snapshotID: "old-snapshot", elementID: "ok")
        let actions: [IOSAction] = [.tap(TapAction(target: stale)), .doubleTap(DoubleTapAction(target: stale)), .longPress(LongPressAction(target: stale)),
                                    .swipe(SwipeAction(target: stale, direction: .up)), .typeText(TypeTextAction(target: stale, text: "x")), .clearText(ClearTextAction(target: stale))]
        for action in actions {
            do { _ = try await executor.execute(action, context: ctx()); Issue.record("\(action.actionType) must reject a stale snapshot") }
            catch { #expect(ActionFailureKind.of(error) == .staleSnapshot, "\(action.actionType)") }
        }
        _ = driver
    }

    @Test func testUnknownTargetIsTargetNotFound() async {
        let (_, executor, obs) = setup()
        for action in [IOSAction.tap(TapAction(target: IOSTestSupport.target(obs, "ghost"))), .doubleTap(DoubleTapAction(target: IOSTestSupport.target(obs, "ghost")))] {
            do { _ = try await executor.execute(action, context: ctx()); Issue.record("must fail") }
            catch { #expect(ActionFailureKind.of(error) == .targetNotFound) }
        }
    }

    @Test func testDisabledAndNonHittableTargetsAreDistinguishedAndNoGestureIsPerformed() async {
        let (driver, executor, obs) = setup()
        do { _ = try await executor.execute(.tap(TapAction(target: IOSTestSupport.target(obs, "off"))), context: ctx()); Issue.record("disabled") }
        catch { #expect(ActionFailureKind.of(error) == .targetDisabled) }
        do { _ = try await executor.execute(.tap(TapAction(target: IOSTestSupport.target(obs, "hidden"))), context: ctx()); Issue.record("hidden") }
        catch { #expect(ActionFailureKind.of(error) == .targetNotHittable) }
        let done = await driver.capturedActions.filter { $0.hasPrefix("tap") }.count
        #expect(done == 2, "attempts were made, but each threw before any state change")
    }

    @Test func testSimulatorFailureIsClassifiedAsSimulatorFailure() async {
        let (driver, executor, obs) = setup()
        await driver.setShouldThrowError(.simulatorNotAvailable("udid"))
        do { _ = try await executor.execute(.tap(TapAction(target: IOSTestSupport.target(obs, "ok"))), context: ctx()); Issue.record("must fail") }
        catch { #expect(ActionFailureKind.of(error) == .simulatorFailure) }
    }

    @Test func testXCTestFailureAndObservationFailureAreClassified() async {
        let (driver, executor, obs) = setup()
        await driver.setShouldThrowError(.actionFailed("xcodebuild exited with status 65"))
        do { _ = try await executor.execute(.tap(TapAction(target: IOSTestSupport.target(obs, "ok"))), context: ctx()); Issue.record("x") }
        catch { #expect(ActionFailureKind.of(error) == .xctestFailure) }
        await driver.setShouldThrowError(.observationFailed("no tree"))
        do { _ = try await executor.execute(.accessibilityTree(AccessibilityTreeAction(bundleID: "b")), context: ctx()); Issue.record("y") }
        catch { #expect(ActionFailureKind.of(error) == .observationFailed) }
    }

    // MARK: Observation, wait

    @Test func testAccessibilityTreeReturnsTheStandardObservation() async throws {
        let (_, executor, obs) = setup()
        let exec = try await executor.execute(.accessibilityTree(AccessibilityTreeAction(bundleID: ProductFixtures.bundleID)), context: ctx())
        #expect(exec.output.observation == obs && exec.result.postObservationID == obs.snapshotID)
        #expect(exec.output.summary.contains("\(obs.elements.count) elements"))
        let state = try await executor.execute(.appState(AppStateAction(bundleID: ProductFixtures.bundleID)), context: ctx())
        #expect(state.output.summary.contains(obs.appState.rawValue))
    }

    @Test func testWaitSucceedsWhenTheElementAppearsInALaterObservation() async throws {
        let first = ProductFixtures.observation("w1", [ProductFixtures.element("a", identifier: "other")])
        let later = ProductFixtures.observation("w2", [ProductFixtures.element("b", identifier: "target-id")])
        let driver = SimulatedDriver(currentSnapshot: first)
        await driver.queueNextSnapshot(first); await driver.queueNextSnapshot(first); await driver.queueNextSnapshot(later)
        let clock = TestClock()
        let exec = try await IOSTestSupport.executor(driver: driver, clock: clock)
            .execute(.waitForElement(WaitForElementAction(identifier: "target-id", timeoutSeconds: 5)), context: ctx())
        #expect(exec.result.success && exec.result.diagnostics["polls"] == "3")
        #expect(exec.result.postObservationID == later.snapshotID)
        #expect(clock.sleepCalls == [0.5, 0.5])
    }

    @Test func testWaitTimesOutWithTimeoutAndBoundedPolling() async {
        let (driver, executor, _) = setup()
        do {
            _ = try await executor.execute(.waitForElement(WaitForElementAction(identifier: "never", timeoutSeconds: 1, pollIntervalSeconds: 0.5)), context: ctx())
            Issue.record("must time out")
        } catch {
            #expect(ActionFailureKind.of(error) == .timeout)
            #expect(error is DriverError)
        }
        let polls = await driver.invokedActionCount["captureObservation"] ?? 0
        #expect(polls == 3, "1s budget at 0.5s => 3 bounded polls")
    }

    // MARK: Fail closed

    @Test func testModeledButUnimplementedActionsFailClosedAndTouchNothing() async {
        let (driver, executor, obs) = setup()
        let t = IOSTestSupport.target(obs, "ok")
        let actions: [IOSAction] = [.keyPress(KeyPressAction(key: .returnKey)), .dismissOverlay(DismissOverlayAction(target: t)),
                                    .selectPickerValue(SelectPickerValueAction(target: t, value: "v")),
                                    .launchApp(LaunchAppAction(bundleID: "b")), .terminateApp(TerminateAppAction(bundleID: "b")), .activateApp(ActivateAppAction(bundleID: "b"))]
        for action in actions {
            do { _ = try await executor.execute(action, context: ctx()); Issue.record("\(action.actionType) must fail closed") }
            catch DriverError.unsupportedCapability(let msg) { #expect(msg.contains("no action was performed")) }
            catch { Issue.record("wrong error \(error)") }
        }
        let actions2 = await driver.capturedActions
        #expect(actions2.isEmpty, "the driver was never invoked")
    }
}
