no live check is meaningful: it reads the trusted snapshot and never touches the deviceno separate live check by design: it is read off the same trusted observation that `accessibility_tree` is live-verified through, and a second mechanism would be a second execution path# iOS Interaction Capability Matrix

Statuses (evidence-based; the word "supported" is not used without evidence):

| Status | Meaning |
| --- | --- |
| `LIVE_VERIFIED` | A real simulator ran real XCTest code, the action happened, a fresh observation changed and trusted verification passed (recorded live run). |
| `IMPLEMENTED_NOT_LIVE_VERIFIED` | Implemented for live execution, but no recorded live run proves it. |
| `SIMULATION_ONLY` | Works in simulation (validates and returns a simulated result). In live mode the driver refuses with `unsupportedCapability` (fails closed). |
| `FAIL_CLOSED` | Typed action exists; there is no descriptor or implementation, so execution throws `unsupportedCapability`. |
| `NOT_SUPPORTED` | Not modeled or implemented. |
| `NOT_APPLICABLE` | Runs on the host, not the device. |

Catalog statuses are asserted by `IOSCatalogHonestyTests`: the `LIVE_VERIFIED` allow-list is `tap_element`, `get_accessibility_tree`,
`double_tap_element`, `long_press_element`, `type_text`, `clear_text`, `scroll`, `drag_and_drop`; this document must contain a row for every
catalog tool with the catalog's status. **Scope of evidence:** every gesture row was verified on the dedicated fixture app only
(runs recorded while the XCUITest runner existed; that runner and its evidence log were removed, and the idb driver is now the only device path); none is evidence about any product app.

## Execution path (single, typed)

```
LLM proposal -> ProposalAdmission (schema + trusted target) -> human approval -> DispatchAuthorizer proof
  -> ScenarioStepDispatcher -> ToolRegistry.execute(_:authorization:) -> ToolResolver (descriptor + schema)
  -> IOSToolAdapter -> IOSActionDecoder (typed IOSAction) -> IOSInteractionExecutor -> IOSPerformable
  -> DeviceDriver -> SimulatorXCTestDriver -> UITestRunner -> xcodebuild -> fresh observation -> verification
```

Read-only tools use `executeReadOnly` and the same resolver/adapter/executor, without an approval.

## Live evidence

`.runs/` holds three `LIVE_HUMAN_APPROVAL` runs of `SCENARIO-LANG-SHEET` (two COMPLETED, one earlier FAILED during hardening):
open language sheet (tap), live observations, dismiss language sheet (tap), trusted verification. Learned skills
`open-language-sheet` / `dismiss-language-sheet` each show 2 verified executions. These runs predate the current
refactor. **Nothing else has recorded live evidence, and this phase performed no live run.**

## Capabilities backed by a tool

Columns: Unit = mock-driver/schema tests; Integration = through `AgentUIState` + controller with a mock driver; Live = recorded live run.

| Capability | Tool | Typed action | XCTest / API actually used | Implemented | Unit | Integration | Live | Verification | Failure handling | Status | Limitations |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Tap | `ios.tap` (`tap_element`) | `TapAction` | fixed XCUITests `testPerformActionOnElement` / `testDismissLanguageSheet`: `XCUIElement.tap()` after `isHittable` | live + simulation | yes | yes | yes (LANG-SHEET) | fresh observation + scenario verification rules | `staleSnapshot`, `targetNotFound`, `targetDisabled`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | only the two fixed test targets; target passed by identifier/label; requires hittable element Arbitrary-target tap is evidenced on the run 8D28FEBB, execution 9B5BCDEC; fixture only (overlay run 3EFFCF43, navigation run 56A67D70, after the target-delivery fix). Earlier language-sheet runs covered only the default control and the named dismiss test. Tab selection by tap is NOT verified (run 5B153447). **2026-09-22:** a tap on the fixture NavigationLink "Next" did not navigate (execution 74985D87), so the capability registry marks tap `INTERMITTENT`. **FROZEN 2026-09-25 (`TAP-FROZEN-2026-09-25`):** intermittent failure has been correlated with a BackBoard TouchEvents anomaly in one recorded failure (BCF0ABEC); causal mechanism remains unproven. Observed sample 4 of 26 valid executions (~15%) — an observed sample frequency, not a probability. Internal investigation is frozen pending external evidence; see `docs/evidence/EVIDENCE_INDEX.md`. |
| Accessibility tree | `ios.accessibility_tree` (`get_accessibility_tree`) | `AccessibilityTreeAction` | fixed XCUITest `testCaptureCurrentAccessibilityTree`, exported JSON | live + simulation | yes | yes | yes | is the observation | `observationFailed` | `LIVE_VERIFIED` | bounded/sanitized by `ObservationFilter`; each capture runs an XCUITest |
| App state | `ios.app_state` (`get_app_state`) | `AppStateAction` | derived from an observation | live + simulation | yes | no | no | n/a (read-only) | `observationFailed` | `LIVE_VERIFIED` | |
| Element details | `ios.element_details` (`get_element_details`) | `ElementDetailsAction` | none (reads the trusted snapshot) | yes | schema/mock | no | no | n/a | `staleSnapshot`, `targetNotFound` | `LIVE_VERIFIED` | no device call |
| Wait for element | `ios.wait_for_element` (`wait_for_element`) | `WaitForElementAction` | polls fresh observations via `ConditionWaiter` (no XCTest wait) | live + simulation | yes (found, appears later, times out, bounded) | no | no | the observation that satisfied the wait | `timeout` (bounded polls, max 30) | `IMPLEMENTED_NOT_LIVE_VERIFIED` | existence by identifier only, bounded polls of fresh observations (max 30, injected clock, no predicates and no coordinates). Not live-verified: no fixture makes an element appear after a delay, so a live run would only re-observe something already present; each live poll is an XCUITest run so wall time can exceed the budget; no hittability/disappearance/predicate wait |
| Inspect elements | `ios.inspect` (`inspect_elements`) | `InspectElementsAction` | fresh XCTest observation + trusted scenario assertions | live + simulation | yes (read-only scenario tests) | yes | no | expected-element assertions | `observationFailed`, `xctestFailure` | `LIVE_VERIFIED` | fixture evidence; expectations come only from the controller-owned scenario |
| Screenshot | `ios.screenshot` (`capture_screenshot`) | `ScreenshotAction` | `xcrun simctl io <udid> screenshot` (host tool) | live + simulation | yes (artifact, checksum, association, execution binding, missing/empty file, non-zero simctl exit) | yes (FIXTURE-SCREENSHOT, read-only) | no | artifact checksum + the read-only invariant on a fresh observation | `observationFailed` when no image file is produced or simctl exits non-zero | `LIVE_VERIFIED` | **2026-09-25:** run EB1F26AD, execution BEA8C199, artifact 0D7FA56D (86 502 bytes, 1206x2622 PNG), verification "Status reads 'tap:idle'" — the screen is verified **unchanged**. Fixture evidence only, not a product app. Full-screen device frame: which app it shows is established by the trusted observations around it, and it proves no application state. Returns an `ArtifactReference` (path only without an artifact store); XCUITest screenshot attachments are separate |
| Double tap | `ios.double_tap` (`double_tap_element`) | `DoubleTapAction` | `ATADoubleTapPerformer`: `XCUIElement.doubleTap()` | live (fixture-targeted) + simulation | yes | yes (mock driver) | yes, fixture only (FIXTURE-DOUBLE-TAP, run 69B438DA) | fresh observation + deterministic status verification | `staleSnapshot`, `targetNotFound`, `targetDisabled`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | Fixture evidence only. That run predates trace correlation: **no executionID was recorded** for it. Restoration = fixture relaunch. |
| Long press | `ios.long_press` (`long_press_element`) | `LongPressAction` | `ATALongPressPerformer`: `press(forDuration:)` with the trusted duration | live (fixture-targeted) + simulation | yes | yes (mock driver) | yes, fixture only (FIXTURE-LONG-PRESS, run EB371CE6, execution FF458E8F) | fresh observation + deterministic status verification | `staleSnapshot`, `targetNotFound`, `targetDisabled`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | Fixture evidence only. A first attempt failed because of a fixture gesture bug, not the runner. |
| Swipe | `ios.swipe` (`swipe`) | `SwipeAction` | `ATASwipePerformer`: `swipeUp/Down/Left/Right()` | live (fixture-targeted) + simulation | yes | yes (mock driver, FIXTURE-SWIPE) | partial: 1 pass (5D1875BC), 1 genuine failure (B00084C5) | fresh observation + deterministic status verification | `staleSnapshot`, `targetNotFound`, `targetDisabled`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | The tool has recorded live runs; the **capability is `INTERMITTENT`** (1 pass 5D1875BC, 1 genuine failure B00084C5). Fixture evidence only, one direction (up on the vertical list). No duration/velocity. |
| Scroll | `ios.scroll` (`scroll`) | `ScrollAction` | `ATAScrollPerformer`: inverse `swipe*()` on the container | live (fixture-targeted) + simulation | yes | yes (mock driver) | partial, fixture only: vertical down and up (run 187DE124), horizontal right (run 8573B07F step 1) | fresh observation + deterministic status verification | `staleSnapshot`, `targetNotFound`, `targetDisabled`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | Verified directions: down, up, left (SA-E2E-003, 2026-09-22), right (intermittent), right at slow velocity (SA-E2E-004). The earlier missing left-scroll attachment was a stale runner. Verification uses an explicit position status because the tree keeps lazy rows. "Scroll until visible" is not implemented. |
| Drag and drop | `ios.drag` (`drag_and_drop`) | `DragAction` | `ATADragPerformer`: `press(forDuration:thenDragTo:)` | live (fixture-targeted) + simulation | yes | yes (mock driver) | yes, fixture only (FIXTURE-DRAG, run E6926663) | fresh observation + deterministic status verification | `staleSnapshot`, `targetNotFound`, `targetDisabled`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | Fixture evidence only. Source and destination are both trusted scenario data; a proposal supplies neither. |
| Type text | `ios.type_text` (`type_text`) | `TypeTextAction` | `ATATypeTextPerformer`: tap, wait for keyboard, `typeText` | live (fixture-targeted) + simulation | yes | yes (mock driver) | yes, fixture only (FIXTURE-TEXT step 1, run 8D28FEBB) | fresh observation + deterministic status verification | `staleSnapshot`, `targetNotFound`, `targetDisabled`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | Fixture evidence only, plain text field. Secure/search fields and keyboard dismissal are not verified. Text travels in the process environment only; the xcresult is deleted. |
| Clear text | `ios.clear_text` (`clear_text`) | `ClearTextAction` | `ATAClearTextPerformer`: tap + delete key presses | live (fixture-targeted) + simulation | yes | yes (mock driver) | yes, fixture only (FIXTURE-TEXT step 2, run 8D28FEBB) | fresh observation + deterministic status verification | `staleSnapshot`, `targetNotFound`, `targetDisabled`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | Fixture evidence only. |
| Navigate back | `ios.back` (`navigate_back`) | `BackAction` | `ATABarButtonPerformer`: the one button matching the identifier/label inside `app.navigationBars`, then `tap()` | live (fixture-targeted) + simulation | yes | yes (mock driver, FIXTURE-BACK-NAVIGATION with preconditions) | no | fresh observation + deterministic status verification | `staleSnapshot`, `targetNotFound` (none or ambiguous in the bar), `targetNotHittable`, `xctestFailure` | `IMPLEMENTED_NOT_LIVE_VERIFIED` | No edge-swipe back. A button outside a navigation bar is never used. |
| Select tab | `ios.select_tab` (`select_tab`) | `SelectTabAction` | `ATABarButtonPerformer`: the one button matching the identifier/label inside `app.tabBars`, then `tap()` | live (fixture-targeted) + simulation | yes | yes (mock driver, FIXTURE-TAB-SELECTION with preconditions) | yes, both directions 2026-09-23 (executions 65479006, FF1B80BE) | fresh observation + status verification + `selectedBecame` signal | `staleSnapshot`, `targetNotFound`, `targetNotHittable`, `xctestFailure` | `LIVE_VERIFIED` | Fixture evidence only. A generic tap on a floating tab bar item did not select it (run 5B153447); this typed tool replaces that path. |
| Dismiss keyboard | `ios.dismiss_keyboard` (`dismiss_keyboard`) | `DismissKeyboardAction` | `ATADismissKeyboardPerformer`: requires a visible keyboard, then `typeText(XCUIKeyboardKey.return)` on the focused field | live (fixture-targeted) + simulation | yes | yes (mock driver, FIXTURE-DISMISS-KEYBOARD with a provisioned keyboard) | yes, 2/2 2026-09-23 (57C0F567, F6282DD0) | fresh observation + status verification + `keyboardBecame` signal | `staleSnapshot`, `targetNotFound`, `keyboardUnavailable`, `xctestFailure` | `LIVE_VERIFIED` | Fixture evidence only. Only fields that resign first responder on Return. No tap-outside dismissal (that would be a coordinate). |
| Project info | `host.project_info` (`get_project_info`) | (host tool) | none | yes | yes | no | n/a | n/a | `toolUnavailable` | `NOT_APPLICABLE` | reads the repository, not the device |

## Capability registry (`IOSCapabilityRegistry`)

The typed capability inventory used by the executor (it refuses a capability in an environment the entry does not declare).
Statuses: `LIVE_VERIFIED` (recorded passing live runs, no failure of the capability itself), `INTERMITTENT` (recorded passing
*and* failing live runs of the capability itself), `UNIT_VERIFIED` (deterministic/integration tests only), `UNVERIFIED`
(implemented; a live attempt did not establish it), `FAIL_CLOSED` (typed, refused), `UNSUPPORTED` (not offered),
`PLATFORM_LIMITATION` (not safely expressible with public APIs). **Environment:** every offered capability is simulator-only.
No physical-device driver exists (`SimulatorXCTestDriver`, simctl screenshots), so no capability declares a physical device
and the executor refuses one (`environment_unsupported`). Asserted by `IOSCapabilityRegistryTests`.

Each entry also exposes derived fields, computed rather than stored so they cannot drift: **action type** (the typed
`IOSAction`, checked against the decoder), **approval requirement** (the catalog's risk: every mutating tool needs a human
approval), **verification strategy** (the fresh post-action observation must show one of the listed signals against the
fresh pre-action observation; the observed application state is the final authority), **evidence requirement** (for a
mutating tool: pre-observation, approval record, action diagnostics, xcresult bundle, application identity,
post-observation; a missing item makes the run `evidence_incomplete`, never passed) and **failure taxonomy** (the
`ActionFailureKind`s it can report; refused capabilities report only `unsupportedCapability`).

| Capability | Status | Environment | Tool (variant) | SDK API | Verification signals | Limitation / evidence |
| --- | --- | --- | --- | --- | --- | --- |
| `tap` | `INTERMITTENT` | simulator | `tap_element` | -[XCUIElement tap] | labelChanged, elementAppeared | fixture passes (runs 3EFFCF43, 56A67D70) and product-app passes on the language sheet (runs F8B78380, B0A9C70E, 4C31CB65, SCENARIO-LANG-SHEET, 2026-09-20; those runs predate execution-ID correlation, so they are cited by run ID and no execution ID exists for them, and per the caveat section they covered only the test's built-in default control, not an arbitrary target) and 4 passes on the reverted fixture (79E32CB1, D1433BD6, C7BDA6DC, 65AB3330, 76B01336, D3F3852D, 6E32C114, DE266120, 7A2581A7, BC49479B). Compared 2026-09-24 (BCF0ABEC vs 6 same-batch passes): identical pre-tap hit region and in-range tap duration, so the hit-region hypothesis is not supported. Earlier reproduction (4330C111): the link never activated; foreground wait 0-1 ms and the failing tap slower than a passing one, disproving both earlier explanations. Earlier reproduction (251AD75B): tap delivered to the correct hittable element, target still present afterwards and the app's own in-process tree still read navigation:root; resolution, hittability, observation timing, stale runner and foreign app excluded; cause not established. **FROZEN 2026-09-25 (`TAP-FROZEN-2026-09-25`):** intermittent failure has been correlated with a BackBoard TouchEvents anomaly in one recorded failure (BCF0ABEC); causal mechanism remains unproven. Observed sample 4 of 26 valid executions (~15%) — an observed sample frequency, not a probability. Internal investigation is frozen pending external evidence; see `docs/evidence/EVIDENCE_INDEX.md`. |
| `double_tap` | `INTERMITTENT` | simulator | `double_tap_element` | -[XCUIElement doubleTap] | labelChanged | 12 of 13 generated-pipeline runs that reached the action passed (828840FF, 00B131F2, C01EF3DA, 40F16399, 4EACAD23, earlier F2DC7897); B9CD0D14 registered a single tap, cause unknown; the touch observer recorded nothing and was reverted |
| `long_press` | `LIVE_VERIFIED` | simulator | `long_press_element` | -[XCUIElement pressForDuration:] | labelChanged | run EB371CE6, execution FF458E8F (fixture); trusted duration only |
| `type_text` | `LIVE_VERIFIED` | simulator | `type_text` | -[XCUIElement typeText:] | valueChanged, labelChanged | run 8D28FEBB, execution 619C839E; plain text field on the fixture; typed text never persisted; no generated form |
| `clear_text` | `LIVE_VERIFIED` | simulator | `clear_text` | -[XCUIElement typeText:] with delete keys | valueChanged, labelChanged | fixture only |
| `scroll_vertical_down` | `LIVE_VERIFIED` | simulator | `scroll` (down) | -[XCUIElement swipeUp] | labelChanged, elementDisappeared | run 187DE124, execution CA12D4EA; position status label on the fixture |
| `scroll_vertical_up` | `LIVE_VERIFIED` | simulator | `scroll` (up) | -[XCUIElement swipeDown] | labelChanged, elementAppeared | tool-level run 187DE124; no generated-pipeline run |
| `scroll_horizontal_right` | `INTERMITTENT` | simulator | `scroll` (right) | -[XCUIElement swipeLeft] | labelChanged, elementDisappeared | tool pass (execution 22863E41, the right-scroll step verified inside run 8573B07F, whose left-scroll teardown then failed, so the run's own record reads FAILED while this step's pass stands), 2 earlier pipeline passes and 2 clean passes 2026-09-23 (72E5321B, 64D38B2F); DCAFEA21 delivered the swipe and the strip did not move; the same shape appeared on the vertical list with the swipe tool (B00084C5), so the intermittency is in how the SwiftUI ScrollView answers a synthesized swipe, not a direction or velocity |
| `scroll_horizontal_left` | `LIVE_VERIFIED` | simulator | `scroll` (left) | -[XCUIElement swipeRight] | labelChanged, elementAppeared | SA-E2E-003 executions A4C0D9FA, 7BBA0082 (hscroll:first-item:4 -> 0, complete evidence); the earlier missing attachment is explained by the stale runner |
| `scroll_horizontal_right_slow` | `LIVE_VERIFIED` | simulator | `scroll` (right+slow) | -[XCUIElement swipeLeftWithVelocity:] (XCUIGestureVelocitySlow) | labelChanged, elementDisappeared | SA-E2E-004 executions 9F7795D1, 3F2B652B, A39D7A96 (3/3). Default velocity has since passed twice cleanly, so slow velocity is NOT established as a fix for DCAFEA21 |
| `swipe` | `INTERMITTENT` | simulator | `swipe` | -[XCUIElement swipeUp/Down/Left/Right] | labelChanged | FIXTURE-SWIPE 2026-09-23: executions 5D1875BC, E545671F, D04E426B, 343F3869, 67F23F6E, 04BB0943 moved the list; execution B00084C5 delivered the same swipe and the list stayed at scroll:first-row:0; same shape as DCAFEA21 |
| `drag_and_drop` | `LIVE_VERIFIED` | simulator | `drag_and_drop` | -[XCUIElement pressForDuration:thenDragToElement:] | labelChanged | run E6926663, execution 1AAF9621; both ends are trusted scenario data |
| `accessibility_tree` | `LIVE_VERIFIED` | simulator | `get_accessibility_tree` | XCUIApplication descendants + exported JSON | — | every live run captures one (latest F2DC7897); bounded to 50 elements; records the observed application's identity |
| `screenshot` | `LIVE_VERIFIED` | simulator | `capture_screenshot` | simctl io screenshot (typed adapter) | — | live-verified 2026-09-25 on the fixture (run EB1F26AD, execution BEA8C199, artifact 0D7FA56D, 86502 bytes, 1206x2622 PNG; earlier verified run A79D6F26 / execution 7CF408D9 ran before the capture path was hardened). Read-only: the FIXTURE-SCREENSHOT scenario declares changesUIState=false and verifies the screen is UNCHANGED (tap:idle). Full screen only: the capture is a device-level simctl frame, so which application it shows is established by the trusted observations around it, not by the capture; it proves no application state. Fixture evidence only - no product-app evidence. Storage is unit-verified end to end (checksum, association to run/scenario/step and executionID in the artifact metadata, no filesystem path in the result, fail-closed when no image is produced or simctl exits non-zero) |
| `app_state` | `LIVE_VERIFIED` | simulator | `get_app_state` | derived from an observation | — | live-verified 2026-09-25 (run 67256797, execution 9C02C0FD, FIXTURE-APP-STATE): read from a fresh live observation (snap_A50ECB6E), reported `runningForeground`, screen verified unchanged (`tap:idle`) on snap_8EB0969B. **Limitation:** verifies the trusted dispatch and fresh-observation path and reports the fixture's current app state; it does **not** establish a state transition, because the fixture stays in the same foreground state, so the observed value is constant. Fixture evidence only. |
| `element_details` | `LIVE_VERIFIED` | simulator | `get_element_details` | trusted snapshot (no device call) | — | live-verified 2026-09-25 (run 850957E0, execution EB61E24A, FIXTURE-ELEMENT-DETAILS): the validated element `elem_7` / `fixture.tap.target` was resolved from the **authorized** snapshot (snap_1DFBF6E6), returning role `button`; the fresh post-action observation (snap_35217072) records the same element as button / enabled / hittable and verifies `tap:idle`. `snapshotID` and `elementID` are supplied by proposal admission; a proposal supplying either is refused. Phase 27 added the missing authorized-snapshot guard (`DriverError.staleSnapshot`), so details can no longer be answered from a superseded snapshot. **Limitation:** reads the trusted snapshot and never touches the device. Fixture evidence only. |
| `wait_for_element` | `UNIT_VERIFIED` | simulator | `wait_for_element` | bounded fresh observations (ConditionWaiter) | — | existence by identifier only, bounded polls of fresh observations (max 30, injected clock, no predicates, no positional or visual fields). Not live-verified. Blocked 2026-09-25 (Phase 21), fixture surface required: the fixture has no delayed or self-driven appearance - two real observations 14s apart on the overlay screen returned the identical identifier set, and fixture.overlay.title stayed absent - every live poll re-activates the app through its own XCUITest run, and the scenario model (one action plus a teardown, all mutating tools) cannot express act-then-wait. A live run today could only find a target already present on poll 1 or time out, so neither is admissible. The contract is unit- and integration-verified only. Phase 23 (2026-09-25) calibrated the proposed activation-count surface before building it and measured that observation runs produce NO scene-phase transition (three consecutive observations of one live process left the navigation trace byte-identical at rootAppear[0]@294,phase-active@384), so no reveal threshold can produce absence-then-presence and the design was dropped unbuilt. Phase 25 (2026-09-25) ran the two bounded live checks that are possible without a fixture or model change, recorded as WAIT-FOR-ELEMENT-CONTRACT-2026-09-25: execution DC49EB2D polled 3 times against 3 separate fresh live observations and failed closed with the typed timeout (no mutation retry), and execution 4697F3FF resolved fixture.tap.target from a fresh live observation on poll 1 with the screen verified unchanged. Those establish live bounded polling, the typed timeout and live identifier resolution; they do NOT establish the absence-to-presence transition, which is why the status is unchanged |
| `inspect_elements` | `LIVE_VERIFIED` | simulator | `inspect_elements` | fresh XCTest observation + trusted scenario assertions | — | live-verified 2026-10-01 on the fixture (run A0084BB0-6347-434B-B59B-43371E563939, execution 001E7D28-9F1C-4517-B01C-8C0D303CC5E5): a Preview request dispatched the trusted FIXTURE-INSPECT-ELEMENTS expectations, captured a fresh real XCTest observation, verified the fixture tap target and status, confirmed the screen unchanged, and refreshed the framebuffer. Expectations are selected only by the controller-owned scenario ID; callers cannot inject them. Fixture evidence only |
| `back_navigation` | `UNIT_VERIFIED` | simulator | `navigate_back` | -[XCUIElement tap] on the one matching button of app.navigationBars | labelChanged, navigationStateChanged | not live-verified: resolution is solved (the fixture's explicit back button is admitted by identifier), but the provisioned pushed state is gone at action time — XCTest's hierarchy shows NavigationBar 'Root' with no action performed (executions 0C837F6E, F7BD2AB2, 359B698A; earlier 47720F1D, 77940C86, 876FFABD); proven 2026-09-24 (F0D4FBA7, 05816469): Detail with nav-events push:0 pop:0 at the approval prompt, then the same process reads Root with push:0 pop:1 before any gesture, so the stack is popped once; traced 2026-09-24 to ~34 s after activation with no scene-phase change (activation, backgrounding and restoration excluded), the navigation-bar query and a second XCTest process attach were both exonerated by a controlled A/B experiment; mechanism unproven and external to this repository; no edge-swipe back and no coordinate fallback |
| `tab_selection` | `LIVE_VERIFIED` | simulator | `select_tab` | -[XCUIElement tap] on the one matching button of app.tabBars | labelChanged, selectedStateChanged | both directions live-verified 2026-09-23: executions 65479006 and FF1B80BE, selected-state signal held; an earlier generic tap on a floating tab bar item did not select it (run 5B153447), which this typed tool replaces |
| `keyboard_dismissal` | `LIVE_VERIFIED` | simulator | `dismiss_keyboard` | -[XCUIElement typeText:] with XCUIKeyboardKeyReturn on the focused field | labelChanged, keyboardVisibilityChanged | live-verified 2026-09-23 with the keyboard provisioned at launch: executions 57C0F567 and F6282DD0, keyboard:visible -> keyboard:hidden, keyboard signal held; the earlier attempt 4A262BC9 found the keyboard view offscreen |
| `system_keyboard_key` | `FAIL_CLOSED` | — | `—` | - | valueChanged | typed KeyPressAction has no tool |
| `sheet_or_modal_dismissal` | `FAIL_CLOSED` | — | `—` | - | elementDisappeared | typed DismissOverlayAction has no tool; a swipe-down sheet dismissal cannot be told apart from a scroll inside the sheet, so it stays refused; dismissing by tapping a labelled close button is `tap` (FIXTURE-OVERLAY) |
| `picker` | `FAIL_CLOSED` | — | `—` | - | valueChanged | typed SelectPickerValueAction has no tool; the fixture has no picker surface to verify a value change against, so semantics cannot be guaranteed |
| `pull_to_refresh` | `UNSUPPORTED` | — | `—` | - | — | expressible as a swipe down at the top of a list, but no typed action or fixture exists |
| `pinch_zoom` | `UNSUPPORTED` | — | `—` | -[XCUIElement pinchWithScale:velocity:] (SDK, unused) | — | public API exists; the SDK says absolute accuracy is not guaranteed; not modeled |
| `rotate_gesture` | `UNSUPPORTED` | — | `—` | -[XCUIElement rotate:withVelocity:] (SDK, unused) | — | public API exists; best-effort synthesis per the SDK; not modeled |
| `text_selection` | `PLATFORM_LIMITATION` | — | `—` | - | — | no public XCUIElement API selects a text range deterministically |
| `system_alert` | `PLATFORM_LIMITATION` | — | `—` | - | — | system alerts belong to SpringBoard, not the app under test; not reachable through the app-scoped typed runner |
| `coordinate_tap` | `UNSUPPORTED` | — | `—` | - | — | deliberately not offered: no raw coordinate execution |

## Generated test pipeline (spec → generated source → trusted step)

Separate from the tool-level status above: whether a *generated* live test for the action has passed end to end through
spec approval, typed generation, SwiftParser validation, action approval, the trusted spine, fresh observation, verification
and complete evidence (`docs/TEST_EXECUTION_PIPELINE.md`). Asserted against `GenerationVocabulary.pipelineEvidenceStatus`.
Statuses: `LIVE_VERIFIED` (a recorded passing pipeline run), `UNIT_VERIFIED` (deterministic + integration tests only),
`FAIL_CLOSED` (no generated form; refused).

| Generated action | Pipeline status | Fixture step | Live runs (hardened pipeline, 2026-09-21/22) |
| --- | --- | --- | --- |
| `tap_element` | `LIVE_VERIFIED` | `FIXTURE-NAVIGATION#0` | TA-E2E-001 passed (execution D5FC429F) |
| `double_tap_element` | `INTERMITTENT` | `FIXTURE-DOUBLE-TAP#0` | passed: BCFE6B50 (first pipeline), F2DC7897, and 828840FF / 00B131F2 on the reverted fixture (2026-09-23). **failed**: B9CD0D14 (the app recognized a single tap; cause unknown). The 2026-09-22 instrumented runs are not counted: that fixture build carried instrumentation that has since been reverted. |
| `long_press_element` | `LIVE_VERIFIED` | `FIXTURE-LONG-PRESS#0` | LPA-E2E-001 passed (execution 67CE5765) |
| `scroll:down` | `LIVE_VERIFIED` | `FIXTURE-SCROLL-VERTICAL#0` | SA-E2E-001 passed (execution FC831262) |
| `scroll:right` | `INTERMITTENT` | `FIXTURE-SCROLL-HORIZONTAL#0` | passed: 22337E18, C73FA5D5 (2026-09-22). **failed**: CEE3C0B6 (the post-observation was of the product app: wrong-application capture, now refused as `applicationIdentityMismatch`); DCAFEA21 (swipe delivered to the right element in the right app, content did not move). |
| `scroll:up` | `UNIT_VERIFIED` | teardown step `FIXTURE-SCROLL-VERTICAL#1` | no live run |
| `scroll:left` | `UNIT_VERIFIED` | teardown step `FIXTURE-SCROLL-HORIZONTAL#1` | no live run |
| `drag_and_drop` | `LIVE_VERIFIED` | `FIXTURE-DRAG#0` | DA-E2E-001 passed (execution AA987A59) |
| `type_text` | `FAIL_CLOSED` | — | typed text may never appear in a stored generated artifact |
| `clear_text` | `FAIL_CLOSED` | — | depends on typed state; no generated form |
| `swipe` | `FAIL_CLOSED` | — | no fixture step |

## Typed actions with no tool (modeled only)

These have a typed `IOSAction` case and an executor performer that throws `unsupportedCapability`. They have no `ToolDescriptor`,
so a model cannot be offered or authorized to run them.

| Capability | Typed action | Status | Notes |
|---|---|---|---|
| Key press (return, delete, escape, tab) | `KeyPressAction` | `FAIL_CLOSED` | XCUITest supports `XCUIKeyboardKey` on hardware-keyboard-enabled simulators; simulator keyboard vs macOS keyboard not separated or verified |
| Dismiss keyboard | `DismissKeyboardAction` | `LIVE_VERIFIED` | now a typed tool (`ios.dismiss_keyboard`); 2/2 live 2026-09-23 (57C0F567, F6282DD0) with the keyboard provisioned at launch |
| Dismiss overlay / sheet / alert | `DismissOverlayAction` | `FAIL_CLOSED` | closing a sheet works today only as a scenario `tap_element` on its close control (`LIVE_VERIFIED` via tap for the language sheet and for the fixture overlay, run 3EFFCF43: open → `overlay open`, dismiss → restored) |
| Back navigation | `BackAction` | `IMPLEMENTED_NOT_LIVE_VERIFIED` | now a typed tool (`ios.back`); not live-verified (see the registry row). Back also works as a scenario `tap_element` on the back control (`LIVE_VERIFIED` via tap on the fixture, run 56A67D70: `navigation:root` → `detail` → `root`) |
| Select tab | `SelectTabAction` | `LIVE_VERIFIED` | now a typed tool (`ios.select_tab`), both directions 2026-09-23 (65479006, FF1B80BE). Tapping a tab item via `ios.tap` was dispatched on the fixture (run 5B153447) but the tab did not change (iOS 26 floating tab bar, text-only items); verification failed closed. NOT verified |
| Select picker value | `SelectPickerValueAction` | `FAIL_CLOSED` | |
| Launch / terminate / activate app | `LaunchAppAction`, `TerminateAppAction`, `ActivateAppAction` | `FAIL_CLOSED` | lifecycle happens inside fixed XCUITests (`launch()`, `activate()`); no lifecycle tool; must never run without authorization |

## Not modeled

| Capability | Status | Notes |
|---|---|---|
| Coordinate tap / `XCUICoordinate` | `NOT_SUPPORTED` | frames from a model are never trusted; no coordinate action exists |
| Predicate / index / descendant queries | `NOT_SUPPORTED` | targets resolve from the trusted snapshot |
| Pinch, rotate, multi-touch, custom gestures | `NOT_SUPPORTED` | |
| System alerts / permission prompts / SpringBoard | `NOT_SUPPORTED` | no interruption monitors |
| Element/region screenshots, hashing, comparison | `NOT_SUPPORTED` | |
| Hittability / disappearance / predicate waits, animation settling | `NOT_SUPPORTED` | |
| Scroll until element visible | `NOT_SUPPORTED` | |

## What is required before any `SIMULATION_ONLY` or `FAIL_CLOSED` row can become `LIVE_VERIFIED`

1. A live implementation exists (a real XCUITest that performs the gesture; today the bundle is a fixed set of tests).
2. It runs on a deterministic fixture (not production app screens) with a `LIVE_HUMAN_APPROVAL` run.
3. A fresh observation shows the expected change and deterministic verification passes.
4. Unit, negative-case and live evidence are recorded, and the catalog status and this table are updated together
   (`IOSCatalogHonestyTests` enforces the allow-list of `LIVE_VERIFIED` tools; adding one is a deliberate change).

## XCTest / system APIs currently used

`XCUIApplication(bundleIdentifier:)`, `launch()`, `activate()`, `XCUIElement.tap()`, `waitForExistence(timeout:)`,
`isHittable`, element queries by identifier/label/type, `XCUIScreen.main.screenshot()` (attachments), `typeText`,
`doubleTap()`, `press(forDuration:)`, `press(forDuration:thenDragTo:)`, `swipeUp/Down/Left/Right()` (typed action runner, fixture-verified while the XCUITest runner existed); host side: `xcodebuild test`, `xcrun simctl io <udid> screenshot`, `xcrun xcresulttool`.

## Next-capability readiness (factual, 2026-09-25)

Recorded after the tap investigation was frozen (`TAP-FROZEN-2026-09-25`). **Nothing here changes a capability status**;
it states, from existing evidence only, what stands between each already-implemented capability and live evidence. The
criteria are factual: implementation present; live evidence missing; blocked by a known external behaviour; testable with
the existing fixture; dependency on another component.

| Capability | Implemented | Live evidence | What is missing | External blocker | Fixture change needed |
|---|---|---|---|---|---|
| `screenshot` | yes (host `simctl io … screenshot`, storage unit-verified end to end) | no | a read-only scenario kind: every fixture scenario today is a mutating action, so a capture has no run to happen in. The uncovered step is the host capture itself. | none recorded | no |
| `wait_for_element` | yes (existence by identifier, bounded polls of fresh observations, injected clock) | no | **Phase 21, blocked:** a surface where an element appears after a delay. Measured 2026-09-25 - two real observations 14s apart on the overlay screen returned the identical identifier set; every live poll re-activates the app; the scenario model cannot express act-then-wait. | none recorded (this is a fixture gap, not external behaviour) | **yes** |
| `back_navigation` | yes (typed target resolves by `fixture.navigation.back`) | no | the pushed state is popped exactly once before the action runs (`F0D4FBA7`, `05816469`). Activation, scene-phase changes, backgrounding, state restoration, accessibility scanning, identity attach, keyboard query and the navigation-bar query are all excluded by controlled experiments. | **yes** — unproven external XCUITest/SwiftUI interaction behaviour | **yes**, if the precondition is to be restored at launch |
| `app_state`, `element_details` | yes | **yes, 2026-09-25** (executions 9C02C0FD and EB61E24A) | nothing: both are now live-verified through read-only fixture scenarios, with their limitations recorded above | none | no |
| `inspect_elements` | yes; trusted scenario expectations only | `FIXTURE-INSPECT-ELEMENTS` | live-certified through Preview on 2026-10-01. | `001E7D28-9F1C-4517-B01C-8C0D303CC5E5` | yes |

On these criteria the capability with an implementation present, live evidence missing, no recorded external blocker and
no fixture change required is **`screenshot`**; `wait_for_element` is the same case except that it needs a fixture
affordance, which is a change to ask about first. `back_navigation` is the one candidate with a recorded external
blocker, so it is not evidence-ready on the current fixture.
