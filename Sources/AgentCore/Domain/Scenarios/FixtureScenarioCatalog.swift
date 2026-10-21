import Foundation

/// Scenarios that run only against the dedicated iOS fixture app (`com.autonomous.agent.fixture`), never against a
/// product app. Every step is fixed here: the tool, the locator, the arguments and the deterministic verification.
/// A proposal can select nothing outside them, and the fixture's `*.status` labels state the outcome so verification
/// never depends on localized text or on anything the model says.
public enum FixtureScenarioCatalog {
    public static let bundleID = "com.autonomous.agent.fixture"

    /// The fixture screen the operator provisions before the run (host-side; not an agent action).
    public static func screen(for scenarioID: String) -> String? { screens[scenarioID] }
    private static let screens: [String: String] = [
        "FIXTURE-TAP": "tap",
        "FIXTURE-DOUBLE-TAP": "doubleTap", "FIXTURE-LONG-PRESS": "longPress", "FIXTURE-TEXT": "text",
        "FIXTURE-SCROLL-VERTICAL": "scrollVertical", "FIXTURE-SCROLL-HORIZONTAL": "scrollHorizontal", "FIXTURE-SCROLL-HORIZONTAL-SLOW": "scrollHorizontal",
        "FIXTURE-DRAG": "drag", "FIXTURE-OVERLAY": "overlay", "FIXTURE-NAVIGATION": "navigation", "FIXTURE-TABS": "tabs",
        "FIXTURE-BACK-NAVIGATION": "navigation", "FIXTURE-TAB-SELECTION": "tabs", "FIXTURE-KEYBOARD-DISMISS": "keyboard",
        "FIXTURE-NAVIGATE-BACK": "navigationCertification", "FIXTURE-DISMISS-KEYBOARD": "keyboardCertification", "FIXTURE-SWIPE": "scrollVertical",
        "FIXTURE-SCREENSHOT": "tap", "FIXTURE-WAIT-TIMEOUT": "tap", "FIXTURE-WAIT-PRESENT": "tap",
        "FIXTURE-APP-STATE": "tap", "FIXTURE-ELEMENT-DETAILS": "tap",
        "FIXTURE-INSPECT-ELEMENTS": "tap", "FIXTURE-ACCESSIBILITY-TREE": "tap"
    ]

    /// Non-secret fixture text. It is still treated as typed text: never logged, traced, prompted or persisted.
    static let fixtureText = "ata-fixture"

    public static let shared = ScenarioCatalog(scenarios: [
        scenario("FIXTURE-TAP", "Tap", changes: "tap:idle → tap:tapped",
                 action: step("tap", "Tap the target", "tap_element", role: "button", id: "fixture.tap.target",
                              label: "Tap target", expects: status("tap:tapped"), precondition: status("tap:idle"))),
        scenario("FIXTURE-DOUBLE-TAP", "Double tap", changes: "doubleTap:idle → doubleTap:double-tapped",
                 action: step("double_tap", "Double tap the target", "double_tap_element", role: "button", id: "fixture.doubleTap.target",
                              label: "Double tap target", expects: status("doubleTap:double-tapped"))),
        scenario("FIXTURE-LONG-PRESS", "Long press", changes: "longPress:idle → longPress:long-pressed",
                 action: step("long_press", "Long press the target", "long_press_element", role: "button", id: "fixture.longPress.target",
                              label: "Long press target", expects: status("longPress:long-pressed"),
                              args: ["durationSeconds": .double(1.2)])),
        scenario("FIXTURE-TEXT", "Type then clear text", changes: "text-length:0 → text-length:\(fixtureText.count) → text-length:0",
                 action: step("type", "Type into the text field", "type_text", role: "textField", id: "fixture.text.field", label: nil,
                              expects: status("text-length:\(fixtureText.count)"), args: ["text": .string(fixtureText)]),
                 teardown: step("clear", "Clear the text field", "clear_text", role: "textField", id: "fixture.text.field", label: nil,
                                expects: status("text-length:0"))),
        scenario("FIXTURE-SCROLL-VERTICAL", "Vertical scroll", changes: "scroll:first-row:0 → not at top → scroll:first-row:0",
                 action: step("scroll_down", "Scroll the list down", "scroll", role: "scrollView", id: "fixture.scroll.vertical", label: nil,
                              expects: leftOrigin(status: "fixture.scroll.status", origin: "scroll:first-row:0"), args: ["direction": .string("down")]),
                 teardown: step("scroll_up", "Scroll the list back up", "scroll", role: "scrollView", id: "fixture.scroll.vertical", label: nil,
                                expects: status("scroll:first-row:0"), args: ["direction": .string("up")])),
        scenario("FIXTURE-SCROLL-HORIZONTAL", "Horizontal scroll", changes: "hscroll:first-item:0 → not at start → hscroll:first-item:0",
                 action: step("scroll_right", "Reveal later items (scroll right)", "scroll", role: "scrollView", id: "fixture.scroll.horizontal", label: nil,
                              expects: leftOrigin(status: "fixture.hscroll.status", origin: "hscroll:first-item:0"), args: ["direction": .string("right")]),
                 teardown: step("scroll_left", "Scroll the strip back left", "scroll", role: "scrollView", id: "fixture.scroll.horizontal", label: nil,
                                expects: status("hscroll:first-item:0"), args: ["direction": .string("left")])),
        // The same step as FIXTURE-SCROLL-HORIZONTAL with one variable changed: the SDK's slow swipe velocity.
        scenario("FIXTURE-SCROLL-HORIZONTAL-SLOW", "Horizontal scroll (slow swipe)", changes: "hscroll:first-item:0 → not at start",
                 action: step("scroll_right_slow", "Reveal later items with a slow swipe", "scroll", role: "scrollView", id: "fixture.scroll.horizontal", label: nil,
                              expects: leftOrigin(status: "fixture.hscroll.status", origin: "hscroll:first-item:0"),
                              args: ["direction": .string("right"), "velocity": .string("slow")])),
        scenario("FIXTURE-DRAG", "Drag and drop", changes: "drag:idle → drag:dropped",
                 action: step("drag", "Drag the source onto the drop zone", "drag_and_drop", role: "button", id: "fixture.drag.source", label: "Drag source",
                              expects: status("drag:dropped"), args: ["holdDurationSeconds": .double(0.3)],
                              destination: ScenarioLocator(role: "other", identifier: "fixture.drag.destination"))),
        scenario("FIXTURE-OVERLAY", "Open and dismiss an overlay", changes: "overlay:closed → overlay open → dismissed",
                 action: step("open", "Open the overlay", "tap_element", role: "button", id: "fixture.overlay.open", label: "Open overlay",
                              expects: ScenarioStepVerification(description: "Overlay is presented",
                                                                requiredElements: [ScenarioExpectedElement(role: "button", identifier: "fixture.overlay.dismiss", requireNonZeroBounds: false)])),
                 teardown: step("dismiss", "Dismiss the overlay", "tap_element", role: "button", id: "fixture.overlay.dismiss", label: "Close",
                                expects: ScenarioStepVerification(description: "Overlay is dismissed and the screen restored",
                                                                  requiredElements: [ScenarioExpectedElement(role: "button", identifier: "fixture.overlay.open", requireNonZeroBounds: false)],
                                                                  forbiddenElements: [ScenarioExpectedElement(role: "button", identifier: "fixture.overlay.dismiss", requireNonZeroBounds: false)]))),
        scenario("FIXTURE-NAVIGATION", "Navigate forward and back", changes: "navigation:root → navigation:detail → navigation:root",
                 action: step("forward", "Open the detail screen", "tap_element", role: "button", id: "fixture.navigation.next", label: "Next",
                              expects: status("navigation:detail")),
                 teardown: step("back", "Navigate back", "tap_element", role: "button", id: nil, label: "Root", expects: status("navigation:root"))),
        // Single-step scenarios for capabilities whose precondition is provisioned at launch (the fixture really starts in that
        // state: a pushed detail screen, a focused field). Each is reproducible on its own and never depends on a previous run.
        scenario("FIXTURE-NAVIGATE-BACK", "Navigate back from a provisioned detail screen", changes: "navigation:detail → navigation:root",
                 action: step("navigate_back", "Go back with the navigation bar back button", "navigate_back", role: "button", id: "fixture.navigation.back", label: "Root",
                              expects: status("navigation:root"), precondition: status("navigation:detail"),
                              signals: [.navigationBarBecame(identifier: "Root")])),
        scenario("FIXTURE-DISMISS-KEYBOARD", "Dismiss a keyboard that is up at launch", changes: "keyboard:visible → keyboard:hidden",
                 action: step("dismiss_keyboard", "Dismiss the keyboard with Return", "dismiss_keyboard", role: "textField", id: "fixture.keyboard.field", label: nil,
                              expects: status("keyboard:hidden"), precondition: status("keyboard:visible"),
                              signals: [.keyboardBecame(visible: false)])),
        scenario("FIXTURE-SWIPE", "Swipe up on the vertical list", changes: "scroll:first-row:0 → a later row",
                 action: step("swipe", "Swipe up on the list", "swipe", role: "scrollView", id: "fixture.scroll.vertical", label: nil,
                              expects: leftOrigin(status: "fixture.scroll.status", origin: "scroll:first-row:0"),
                              args: ["direction": .string("up")], precondition: status("scroll:first-row:0"))),
        // Typed semantic tools. Each step states its precondition, which is checked on the fresh observation before admission.
        scenario("FIXTURE-BACK-NAVIGATION", "Navigate back with the navigation bar", changes: "navigation:root → navigation:detail → navigation:root",
                 action: step("forward", "Open the detail screen", "tap_element", role: "button", id: "fixture.navigation.next", label: "Next",
                              expects: status("navigation:detail"), precondition: status("navigation:root"),
                              signals: [.navigationBarBecame(identifier: "Detail")]),
                 teardown: step("back", "Go back with the navigation bar back button", "navigate_back", role: "button", id: "fixture.navigation.back", label: "Root",
                                expects: status("navigation:root"), precondition: status("navigation:detail"),
                                signals: [.navigationBarBecame(identifier: "Root")])),
        scenario("FIXTURE-TAB-SELECTION", "Select tabs in the tab bar", changes: "tab:first → tab:second → tab:first",
                 action: step("select_second", "Select the Second tab", "select_tab", role: "button", id: nil, label: "Second",
                              expects: status("tab:second"), precondition: status("tab:first"),
                              signals: [.selectedBecame(SignalLocator(role: "button", label: "Second"))]),
                 teardown: step("select_first", "Select the First tab", "select_tab", role: "button", id: nil, label: "First",
                                expects: status("tab:first"), precondition: status("tab:second"),
                                signals: [.selectedBecame(SignalLocator(role: "button", label: "First"))])),
        scenario("FIXTURE-KEYBOARD-DISMISS", "Show and dismiss the keyboard", changes: "keyboard:hidden → keyboard:visible → keyboard:hidden",
                 action: step("focus", "Focus the text field", "tap_element", role: "textField", id: "fixture.keyboard.field", label: nil,
                              expects: status("keyboard:visible"), precondition: status("keyboard:hidden"),
                              signals: [.keyboardBecame(visible: true)]),
                 teardown: step("dismiss", "Dismiss the keyboard with Return", "dismiss_keyboard", role: "textField", id: "fixture.keyboard.field", label: nil,
                                expects: status("keyboard:hidden"), precondition: status("keyboard:visible"),
                                signals: [.keyboardBecame(visible: false)])),
        scenario("FIXTURE-TABS", "Select a tab and return", changes: "tab:first → tab:second → tab:first",
                 action: step("second", "Select the second tab", "tap_element", role: "button", id: nil, label: "Second", expects: status("tab:second")),
                 teardown: step("first", "Select the first tab", "tap_element", role: "button", id: nil, label: "First", expects: status("tab:first"))),
        // Read-only capability. The capture changes nothing, so the scenario declares `changesUIState = false` and the
        // step verifies the screen is *unchanged*: it targets the tap button, whose status label would read
        // `tap:tapped` if the capture had activated anything. Capture evidence is the artifact; this check only
        // establishes that the read-only contract held.
        readOnlyScenario("FIXTURE-SCREENSHOT", "Screenshot", unchanged: "tap:idle (unchanged; the capture mutates nothing)",
                         action: step("screenshot", "Capture screenshot evidence of the current screen", "capture_screenshot",
                                      role: "button", id: "fixture.tap.target", label: "Tap target",
                                      expects: status("tap:idle"), args: ["reason": .string("Live verification of the screenshot capability")],
                                      precondition: status("tap:idle"))),
        // Read-only capability. Two bounded checks of the same tool, both on the provisioned tap screen and neither
        // touching the device: the wait polls fresh observations and nothing else. Between them they exercise the two
        // outcomes the implementation has - a target that never appears (bounded polls, typed timeout, fail-closed) and
        // a target that is there (identifier resolution from a fresh observation). Neither observes an appearance, so
        // neither says anything about waiting across a transition.
        readOnlyScenario("FIXTURE-WAIT-TIMEOUT", "Wait for an element that is not there",
                         unchanged: "tap:idle (unchanged; the wait only observes) - the wait is expected to time out",
                         action: step("wait_absent", "Wait for an identifier the screen does not contain", "wait_for_element",
                                      role: "button", id: "fixture.tap.target", label: "Tap target",
                                      expects: status("tap:idle"),
                                      args: ["identifier": .string("fixture.wait.absent"), "timeoutSeconds": .double(1.0)],
                                      precondition: status("tap:idle"))),
        readOnlyScenario("FIXTURE-WAIT-PRESENT", "Wait for an element that is there",
                         unchanged: "tap:idle (unchanged; the wait only observes)",
                         action: step("wait_present", "Wait for an identifier the screen does contain", "wait_for_element",
                                      role: "button", id: "fixture.tap.target", label: "Tap target",
                                      expects: status("tap:idle"),
                                      args: ["identifier": .string("fixture.tap.target"), "timeoutSeconds": .double(1.0)],
                                      precondition: status("tap:idle"))),
        // Read-only observation capabilities. Both read the trusted observation and touch nothing, so each scenario
        // verifies the screen is unchanged; what the tool returned is recorded as evidence, never as the verification.
        readOnlyScenario("FIXTURE-APP-STATE", "Read the application state", unchanged: "tap:idle (unchanged; the read touches nothing)",
                         action: step("app_state", "Read the application state from a fresh observation", "get_app_state",
                                      role: "button", id: "fixture.tap.target", label: "Tap target",
                                      expects: status("tap:idle"), precondition: status("tap:idle"))),
        // `snapshotID` and `elementID` are supplied by proposal admission from trusted validation state; a proposal
        // that tries to supply either is refused as a security-boundary violation, so they are never step arguments.
        readOnlyScenario("FIXTURE-ELEMENT-DETAILS", "Read element details", unchanged: "tap:idle (unchanged; the read touches nothing)",
                         action: step("element_details", "Read the details of the validated element", "get_element_details",
                                      role: "button", id: "fixture.tap.target", label: "Tap target",
                                      expects: status("tap:idle"), precondition: status("tap:idle"))),
        readOnlyScenario("FIXTURE-INSPECT-ELEMENTS", "Inspect elements", unchanged: "tap:idle (unchanged; inspection only observes)",
                         action: step("inspect", "Inspect the fixture tap screen", "inspect_elements",
                                      role: "button", id: "fixture.tap.target", label: "Tap target",
                                      expects: status("tap:idle"), precondition: status("tap:idle")),
                         expectedElements: [
                            ScenarioExpectedElement(role: "button", identifier: "fixture.tap.target", label: "Tap target", requireNonZeroBounds: true, requireEnabled: true, requireHittable: true),
                            ScenarioExpectedElement(role: "other", identifier: "fixture.tap.status", requireNonZeroBounds: false)
                         ]),
        readOnlyScenario("FIXTURE-ACCESSIBILITY-TREE", "Accessibility tree refresh", unchanged: "tap:idle (unchanged; refresh only observes)",
                         action: step("accessibility_tree", "Refresh the accessibility tree", "get_accessibility_tree",
                                      role: "button", id: "fixture.tap.target", label: "Tap target",
                                      expects: status("tap:idle"), precondition: status("tap:idle")))
    ])

    // MARK: - Builders

    /// A status line is matched by its label alone (no identifier), so a stale label can never satisfy the check.
    private static func status(_ label: String) -> ScenarioStepVerification {
        ScenarioStepVerification(description: "Status reads '\(label)'",
                                 requiredElements: [ScenarioExpectedElement(role: "staticText", label: label, requireNonZeroBounds: false)])
    }

    /// Scrolled away from the origin: the position status exists but no longer reads the origin label.
    private static func leftOrigin(status identifier: String, origin: String) -> ScenarioStepVerification {
        ScenarioStepVerification(description: "Scrolled away from '\(origin)'",
                                 requiredElements: [ScenarioExpectedElement(role: "other", identifier: identifier, requireNonZeroBounds: false)],
                                 forbiddenElements: [ScenarioExpectedElement(role: "staticText", label: origin, requireNonZeroBounds: false)])
    }

    private static func step(_ id: String, _ name: String, _ tool: String, role: String, id identifier: String?, label: String?,
                             expects: ScenarioStepVerification, args: [String: AnyCodableValue] = [:],
                             destination: ScenarioLocator? = nil, precondition: ScenarioStepVerification? = nil,
                             signals: [ObservationSignal] = []) -> ScenarioStep {
        ScenarioStep(id: "step_fixture_\(id)", name: name, description: name, toolName: tool,
                     locator: ScenarioLocator(role: role, identifier: identifier, label: label), verification: expects, trustedArguments: args, destination: destination,
                     precondition: precondition, signals: signals)
    }

    /// A scenario whose step cannot change the app. `changesUIState = false` restricts the trusted validator to the
    /// read-only tools of `SafeScenario.readOnlyScenarioTools`, and there is nothing to tear down.
    private static func readOnlyScenario(_ id: String, _ name: String, unchanged: String, action: ScenarioStep,
                                         expectedElements: [ScenarioExpectedElement] = []) -> SafeScenario {
        SafeScenario(id: id, name: "Fixture: \(name)", purpose: "Verify the \(name.lowercased()) capability on the fixture app.",
                     initialStateRequirement: "Fixture app is running on its provisioned screen in its initial state.",
                     expectedPostActionState: unchanged, changesUIState: false, actionStep: action, teardownStep: nil,
                     expectedElements: expectedElements)
    }

    private static func scenario(_ id: String, _ name: String, changes: String, action: ScenarioStep, teardown: ScenarioStep? = nil) -> SafeScenario {
        SafeScenario(id: id, name: "Fixture: \(name)", purpose: "Verify the \(name.lowercased()) capability on the fixture app.",
                     initialStateRequirement: "Fixture app is running on its provisioned screen in its initial state.",
                     expectedPostActionState: changes, changesUIState: true, actionStep: action, teardownStep: teardown)
    }
}
