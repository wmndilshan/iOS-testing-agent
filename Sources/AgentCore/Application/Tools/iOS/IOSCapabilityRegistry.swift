import Foundation

/// Evidence status of one interaction capability. Finer than the catalog's `LiveAvailability`: `INTERMITTENT` and
/// `LIVE_VERIFIED` both need at least one recorded passing live run (so the tool is `LIVE_VERIFIED` in the catalog);
/// `INTERMITTENT` also has a recorded live failure of the capability itself.
public enum IOSCapabilityStatus: String, Codable, Sendable, CaseIterable {
    case liveVerified = "LIVE_VERIFIED"
    case intermittent = "INTERMITTENT"
    /// Implemented; deterministic and integration tests only.
    case unitVerified = "UNIT_VERIFIED"
    /// Implemented, but a live attempt did not establish it and the cause is not yet resolved.
    case unverified = "UNVERIFIED"
    /// Typed but deliberately refused by the executor (no descriptor or live implementation).
    case failClosed = "FAIL_CLOSED"
    /// Not modeled. It could be expressed with public APIs but is deliberately not offered.
    case unsupported = "UNSUPPORTED"
    /// Not expressible safely with the idb / simctl commands this project may use.
    case platformLimitation = "PLATFORM_LIMITATION"
}

/// What a capability acts on.
public enum IOSTargetRequirement: String, Codable, Sendable {
    case element, container, sourceAndDestination, application, none
}

/// A deterministic signal that verification compares between the fresh pre- and post-action observations.
public enum IOSVerificationSignal: String, Codable, Sendable, CaseIterable {
    case elementAppeared, elementDisappeared, labelChanged, valueChanged, foregroundApplication, accessibilitySnapshotChanged
    case selectedStateChanged, navigationStateChanged, keyboardVisibilityChanged
}

/// One interaction capability: how it is expressed, what it needs, how it is verified, where it can run, and what is proven.
public struct IOSCapability: Sendable, Equatable {
    public let id: String
    /// The catalog tool that executes it, if any (plus the trusted argument that distinguishes it, e.g. a direction).
    public let tool: String?
    public let variant: String?
    public let target: IOSTargetRequirement
    /// The one public API used (never a coordinate injection).
    public let api: String
    /// Signals verification must see change; empty for observations.
    public let verification: [IOSVerificationSignal]
    /// Environments the trusted pipeline accepts it in. Empty means refused everywhere.
    public let environments: Set<ExecutionEnvironmentKind>
    public let status: IOSCapabilityStatus
    public let limitation: String
    /// The typed `IOSAction.actionType` this capability is expressed as, or nil when no typed action exists.
    public let actionType: String?

    public init(id: String, tool: String?, variant: String?, target: IOSTargetRequirement, api: String, verification: [IOSVerificationSignal],
                environments: Set<ExecutionEnvironmentKind>, status: IOSCapabilityStatus, limitation: String, actionType: String? = nil) {
        self.id = id; self.tool = tool; self.variant = variant; self.target = target; self.api = api; self.verification = verification
        self.environments = environments; self.status = status; self.limitation = limitation
        self.actionType = actionType ?? tool.flatMap { IOSCapabilityRegistry.actionTypeByTool[$0] }
    }

    // Derived fields. They are computed from the catalog and the verification signals so they cannot drift from them.

    /// Whether a human must approve each execution (the catalog's risk classification is the authority).
    public var requiresApproval: Bool { tool.flatMap { ToolCatalog.descriptor(for: $0)?.requiresApproval } ?? false }

    /// How the outcome is decided. The application state observed after the action is the final authority.
    public var verificationStrategy: String {
        guard tool != nil else { return "none: refused before any device call" }
        if verification.isEmpty { return "read-only: the observation itself, with the observed application identity" }
        return "fresh post-action observation must show " + verification.map(\.rawValue).joined(separator: " or ") + " against the fresh pre-action observation"
    }

    /// Evidence a run must record before its result can be trusted; missing evidence makes the run evidence-incomplete, never passed.
    public var evidenceRequirement: [String] {
        guard tool != nil else { return [] }
        if !requiresApproval { return ["observation", "application_identity"] }
        return ["pre_observation", "approval_record", "action_diagnostics", "xcresult_bundle", "application_identity", "post_observation"]
    }

    /// The failure kinds this capability can report. Refused capabilities only ever report `unsupportedCapability`.
    public var failureTaxonomy: [ActionFailureKind] {
        guard tool != nil else { return [.unsupportedCapability] }
        var kinds: [ActionFailureKind] = [.unsupportedCapability, .timeout, .driverFailure, .simulatorFailure, .xctestFailure, .observationFailed]
        switch target {
        case .element, .container: kinds += [.staleSnapshot, .targetNotFound, .targetNotHittable, .targetDisabled]
        case .sourceAndDestination: kinds += [.staleSnapshot, .targetNotFound, .targetNotHittable]
        case .application, .none: break
        }
        if actionType == "dismiss_keyboard" || actionType == "type_text" { kinds.append(.keyboardUnavailable) }
        if requiresApproval { kinds += [.authorizationFailed, .verificationFailed, .noProgress] }
        return kinds
    }
}

/// The capability layer's single source of truth. Behavior never depends on `status` (it documents evidence); it does
/// depend on `environments`: a capability is refused in an environment it does not declare.
public enum IOSCapabilityRegistry {
    static let sim: Set<ExecutionEnvironmentKind> = [.simulator]

    /// Catalog tool -> typed `IOSAction.actionType` (checked against the decoder by tests).
    static let actionTypeByTool: [String: String] = [
        "tap_element": "tap", "double_tap_element": "double_tap", "long_press_element": "long_press", "type_text": "type_text",
        "clear_text": "clear_text", "scroll": "scroll", "swipe": "swipe", "drag_and_drop": "drag", "get_accessibility_tree": "accessibility_tree",
        "capture_screenshot": "screenshot", "get_app_state": "app_state", "get_element_details": "element_details",
        "wait_for_element": "wait_for_element", "inspect_elements": "inspect_elements",
        "navigate_back": "back", "select_tab": "select_tab", "dismiss_keyboard": "dismiss_keyboard",
    ]

    public static let all: [IOSCapability] = [
        // Touch
        .init(id: "tap", tool: "tap_element", variant: nil, target: .element, api: "-[XCUIElement tap]", verification: [.labelChanged, .elementAppeared],
              environments: sim, status: .intermittent, limitation: "fixture passes (runs 3EFFCF43, 56A67D70) and product-app passes on the language sheet (runs F8B78380, B0A9C70E, 4C31CB65, SCENARIO-LANG-SHEET, 2026-09-20; those runs predate execution-ID correlation, so they are cited by run ID and no execution ID exists for them, and per the caveat section they covered only the test's built-in default control, not an arbitrary target) and 4 passes on the reverted fixture (79E32CB1, D1433BD6, C7BDA6DC, 65AB3330, 76B01336, D3F3852D, 6E32C114, DE266120, 7A2581A7, BC49479B). Compared 2026-09-24 (failure BCF0ABEC against 6 same-batch passes): the pre-tap hit region is identical in every observable property (frame, 21 candidates, 13 overlaps, 0 foreign overlaps, 0 duplicate identifiers, enabled, hittable) and tap duration sits inside the passing range, so the hit-region hypothesis is not supported. Earlier reproduction on the aligned path (execution 4330C111): the link never activated (nav-events push:0 pop:0 in the same process, no relaunch), while foregroundWaitMs was 0-1 ms in all runs and the failing tap took longer (985 ms) than a passing one (854 ms), disproving both the foreground-wait and the tap-duration explanations. Earlier reproduction (execution 251AD75B, xcresult 1FC60355): resolved by identifier, enabled and hittable, tap delivered, targetExistsAfter=true and the app's own tree in the same process still read navigation:root, so the gesture reached the element and SwiftUI did not activate the link. Target resolution, hittability, observation timing, stale runner and foreign application are all excluded; the cause is not established. FROZEN 2026-09-25 (TAP-FROZEN-2026-09-25): intermittent failure has been correlated with a BackBoard TouchEvents anomaly in one recorded failure (BCF0ABEC); causal mechanism remains unproven. Observed sample 4 of 26 valid executions (~15%), an observed sample frequency and not a probability. Internal investigation is frozen pending external evidence"),
        .init(id: "double_tap", tool: "double_tap_element", variant: nil, target: .element, api: "-[XCUIElement doubleTap]", verification: [.labelChanged],
              environments: sim, status: .intermittent, limitation: "12 of 13 generated-pipeline runs that reached the action passed (828840FF, 00B131F2, C01EF3DA, 40F16399, 4EACAD23, earlier F2DC7897); B9CD0D14 registered a single tap, cause unknown; the touch observer recorded nothing and was reverted"),
        .init(id: "long_press", tool: "long_press_element", variant: nil, target: .element, api: "-[XCUIElement pressForDuration:]", verification: [.labelChanged],
              environments: sim, status: .liveVerified, limitation: "run EB371CE6, execution FF458E8F (fixture); trusted duration only"),
        // Text
        .init(id: "type_text", tool: "type_text", variant: nil, target: .element, api: "-[XCUIElement typeText:]", verification: [.valueChanged, .labelChanged],
              environments: sim, status: .liveVerified, limitation: "run 8D28FEBB, execution 619C839E; plain text field on the fixture; typed text never persisted; no generated form"),
        .init(id: "clear_text", tool: "clear_text", variant: nil, target: .element, api: "-[XCUIElement typeText:] with delete keys", verification: [.valueChanged, .labelChanged],
              environments: sim, status: .liveVerified, limitation: "run 8D28FEBB, execution 9B5BCDEC; fixture only"),
        // Scroll / swipe / drag
        .init(id: "scroll_vertical_down", tool: "scroll", variant: "down", target: .container, api: "-[XCUIElement swipeUp]", verification: [.labelChanged, .elementDisappeared],
              environments: sim, status: .liveVerified, limitation: "run 187DE124, execution CA12D4EA; position status label on the fixture"),
        .init(id: "scroll_vertical_up", tool: "scroll", variant: "up", target: .container, api: "-[XCUIElement swipeDown]", verification: [.labelChanged, .elementAppeared],
              environments: sim, status: .liveVerified, limitation: "tool-level run 187DE124; no generated-pipeline run"),
        .init(id: "scroll_horizontal_right", tool: "scroll", variant: "right", target: .container, api: "-[XCUIElement swipeLeft]", verification: [.labelChanged, .elementDisappeared],
              environments: sim, status: .intermittent, limitation: "tool pass (execution 22863E41, the right-scroll step verified inside run 8573B07F, whose left-scroll teardown then failed, so the run's own record reads FAILED while this step's pass stands), 2 earlier pipeline passes and 2 clean passes 2026-09-23 (72E5321B, 64D38B2F, both first-item:0 -> 4); DCAFEA21 delivered the swipe and the strip did not move. The same shape appeared on the vertical list with the swipe tool (B00084C5), so the intermittency is in how the SwiftUI ScrollView answers a synthesized swipe, not in a direction or a velocity"),
        .init(id: "scroll_horizontal_left", tool: "scroll", variant: "left", target: .container, api: "-[XCUIElement swipeRight]", verification: [.labelChanged, .elementAppeared],
              environments: sim, status: .liveVerified, limitation: "SA-E2E-003 executions A4C0D9FA, 7BBA0082 (hscroll:first-item:4 -> 0, complete evidence); the earlier missing attachment is explained by the stale runner"),
        .init(id: "scroll_horizontal_right_slow", tool: "scroll", variant: "right+slow", target: .container, api: "-[XCUIElement swipeLeftWithVelocity:] (XCUIGestureVelocitySlow)",
              verification: [.labelChanged, .elementDisappeared], environments: sim, status: .liveVerified,
              limitation: "SA-E2E-004 executions 9F7795D1, 3F2B652B, A39D7A96 (3/3). Default velocity has since passed twice cleanly, so slow velocity is NOT established as a fix for DCAFEA21; the two variants simply have no recorded failure each in a small sample"),
        .init(id: "swipe", tool: "swipe", variant: nil, target: .element, api: "-[XCUIElement swipeUp/Down/Left/Right]", verification: [.labelChanged],
              environments: sim, status: .intermittent,
              limitation: "FIXTURE-SWIPE (swipe up on the vertical list) 2026-09-23: executions 5D1875BC, E545671F, D04E426B, 343F3869, 67F23F6E and 04BB0943 moved the list; execution B00084C5 delivered the same swipe and the list stayed at scroll:first-row:0. Same failure shape as the scroll intermittency (DCAFEA21)"),
        .init(id: "drag_and_drop", tool: "drag_and_drop", variant: nil, target: .sourceAndDestination, api: "-[XCUIElement pressForDuration:thenDragToElement:]", verification: [.labelChanged],
              environments: sim, status: .liveVerified, limitation: "run E6926663, execution 1AAF9621; both ends are trusted scenario data"),
        // Observation (read-only; no approval needed for the read-only tools, still typed and cataloged)
        .init(id: "accessibility_tree", tool: "get_accessibility_tree", variant: nil, target: .application, api: "XCUIApplication descendants + exported JSON",
              verification: [], environments: sim, status: .liveVerified, limitation: "every live run captures one (latest F2DC7897); bounded to 50 elements; records the observed application's identity"),
        .init(id: "screenshot", tool: "capture_screenshot", variant: nil, target: .application, api: "simctl io screenshot (typed adapter)",
              verification: [], environments: sim, status: .liveVerified,
              limitation: "live-verified 2026-09-25 on the fixture (run EB1F26AD, execution BEA8C199, artifact 0D7FA56D, 86502 bytes, 1206x2622 PNG; earlier verified run A79D6F26 / execution 7CF408D9 ran before the capture path was hardened). Read-only: the FIXTURE-SCREENSHOT scenario declares changesUIState=false and verifies the screen is UNCHANGED (tap:idle). Full screen only: the capture is a device-level simctl frame, so which application it shows is established by the trusted observations around it, not by the capture; it proves no application state. Fixture evidence only - no product-app evidence. Storage is unit-verified end to end (checksum, association to run/scenario/step and executionID in the artifact metadata, no filesystem path in the result, fail-closed when no image is produced or simctl exits non-zero)"),
        .init(id: "app_state", tool: "get_app_state", variant: nil, target: .application, api: "derived from an observation", verification: [],
              environments: sim, status: .liveVerified,
              limitation: "live-verified 2026-09-25 on the fixture (run 67256797, execution 9C02C0FD, FIXTURE-APP-STATE): dispatched through the trusted spine with a real human approval, read the state from a fresh live observation (snap_A50ECB6E) and reported runningForeground, with the fresh post-action observation (snap_8EB0969B) verifying the screen unchanged at tap:idle. LIMITATION: the live evidence verifies the trusted dispatch and fresh-observation path and reports the fixture's current app state; it does NOT establish a state transition, because the fixture remains in the same foreground state throughout a run, so the observed value is constant. Fixture evidence only - no product-app evidence. It is still read off the same trusted observation that accessibility_tree is live-verified through; no second mechanism was introduced"),
        .init(id: "element_details", tool: "get_element_details", variant: nil, target: .element, api: "trusted snapshot (no device call)", verification: [],
              environments: sim, status: .liveVerified,
              limitation: "live-verified 2026-09-25 on the fixture (run 850957E0, execution EB61E24A, FIXTURE-ELEMENT-DETAILS): the validated element elem_7 / fixture.tap.target was resolved from the AUTHORIZED snapshot (snap_1DFBF6E6) and returned role button; the fresh post-action observation (snap_35217072) records the same element as button / fixture.tap.target / enabled / hittable and verifies the screen unchanged at tap:idle. snapshotID and elementID are supplied by proposal admission from trusted validation state and a proposal that supplies either is refused. A stale-snapshot regression previously allowed getElementDetails to resolve against the driver's latest snapshot instead of the authorized snapshot; it now throws DriverError.staleSnapshot. LIMITATION: it reads the trusted snapshot and never touches the device, so the evidence covers the dispatch and resolution path, not new device behaviour. Fixture evidence only"),
        .init(id: "wait_for_element", tool: "wait_for_element", variant: nil, target: .element, api: "bounded fresh observations (ConditionWaiter)", verification: [],
              environments: sim, status: .unitVerified, limitation: "existence by identifier only, bounded polls of fresh observations (max 30, injected clock, no predicates, no positional or visual fields). Not live-verified. Blocked 2026-09-25; fixture surface required: the fixture has no delayed or self-driven appearance. Two real observations 14s apart returned the same identifier set, and observation runs produced no scene-lifecycle transition, so an absence-to-presence transition cannot be certified without changing the fixture. WAIT-FOR-ELEMENT-CONTRACT-2026-09-25 records the available bounded checks: execution DC49EB2D polled three fresh observations and failed closed with a typed timeout; execution 4697F3FF resolved fixture.tap.target on the first fresh observation. These establish bounded polling, timeout behavior, and identifier resolution, but not an absence-to-presence transition"),
        .init(id: "inspect_elements", tool: "inspect_elements", variant: nil, target: .application, api: "fresh XCTest observation + trusted scenario assertions", verification: [],
              environments: sim, status: .liveVerified, limitation: "live-verified 2026-10-01 on the fixture (run A0084BB0-6347-434B-B59B-43371E563939, execution 001E7D28-9F1C-4517-B01C-8C0D303CC5E5): a Preview request dispatched the trusted FIXTURE-INSPECT-ELEMENTS expectations, captured a fresh real XCTest observation, verified the fixture tap target and status, confirmed the screen unchanged, and refreshed the framebuffer. Expectations are selected only by the controller-owned scenario ID; callers cannot inject them. Fixture evidence only"),
        // Navigation: typed semantic tools. Each resolves its button only inside the owning bar, never by coordinates.
        .init(id: "back_navigation", tool: "navigate_back", variant: nil, target: .element, api: "-[XCUIElement tap] on the one matching button of app.navigationBars",
              verification: [.labelChanged, .navigationStateChanged], environments: sim, status: .unitVerified,
              limitation: "not live-verified. Resolution is solved: with the fixture's explicit navigation-bar back button the validator admits the typed target by identifier (fixture.navigation.back). The run still fails because the provisioned pushed state is gone by the time the action runs: at provisioning the screenshot shows Detail, the precondition observation reads navigation:detail, and XCTest's hierarchy at failure shows NavigationBar 'Root' with no action performed (executions 0C837F6E, F7BD2AB2, 359B698A; earlier 47720F1D, 77940C86, 876FFABD). Proven 2026-09-24 (executions F0D4FBA7, 05816469): at the approval prompt the app is on Detail with nav-events push:0 pop:0, and in the action process the same process reads NavigationBar Root with push:0 pop:1 before any gesture, so the stack is popped exactly once. Traced 2026-09-24: the pop lands ~34 s after the scene became active with no scene-phase change in between, so activation, backgrounding and state restoration are excluded; a controlled A/B experiment then exonerated the navigation-bar query itself (both variants kept navigation:detail; in isolation the query even found the button) and also exonerated a second XCTest process attaching. Activation, scene-phase changes, backgrounding, state restoration, accessibility scanning, identity attach and the keyboard query are likewise excluded. The mechanism is an unproven external XCUITest/SwiftUI interaction behaviour. No workaround was applied because every available one would invalidate the test. No edge-swipe back and no coordinate fallback"),
        .init(id: "tab_selection", tool: "select_tab", variant: nil, target: .element, api: "-[XCUIElement tap] on the one matching button of app.tabBars",
              verification: [.labelChanged, .selectedStateChanged], environments: sim, status: .liveVerified,
              limitation: "both directions live-verified 2026-09-23: executions 65479006 (tab:first -> tab:second) and FF1B80BE (back to tab:first), selected-state signal held; an earlier generic tap on a floating tab bar item did not select it (run 5B153447), which this typed tool replaces"),
        .init(id: "keyboard_dismissal", tool: "dismiss_keyboard", variant: nil, target: .element, api: "-[XCUIElement typeText:] with XCUIKeyboardKeyReturn on the focused field",
              verification: [.labelChanged, .keyboardVisibilityChanged], environments: sim, status: .liveVerified,
              limitation: "live-verified 2026-09-23 with the keyboard provisioned at launch (fixture.keyboard.autofocus): executions 57C0F567 and F6282DD0, keyboard:visible -> keyboard:hidden, keyboard signal held. Only fields that resign on Return; a keyboard the app does not raise itself cannot be dismissed (the earlier attempt 4A262BC9 found the keyboard view offscreen)"),
        .init(id: "system_keyboard_key", tool: nil, variant: nil, target: .application, api: "-", verification: [.valueChanged],
              environments: [], status: .failClosed, limitation: "typed KeyPressAction has no tool"),
        .init(id: "sheet_or_modal_dismissal", tool: nil, variant: nil, target: .element, api: "-", verification: [.elementDisappeared],
              environments: [], status: .failClosed, limitation: "typed DismissOverlayAction has no tool; a swipe-down sheet dismissal cannot be told apart from a scroll inside the sheet, so it stays refused; dismissing by tapping a labelled close button is `tap` (FIXTURE-OVERLAY)"),
        .init(id: "picker", tool: nil, variant: nil, target: .element, api: "-", verification: [.valueChanged],
              environments: [], status: .failClosed, limitation: "typed SelectPickerValueAction has no tool; the fixture has no picker surface to verify a value change against, so semantics cannot be guaranteed"),
        // Not offered
        .init(id: "pull_to_refresh", tool: nil, variant: nil, target: .container, api: "-", verification: [],
              environments: [], status: .unsupported, limitation: "expressible as a swipe down at the top of a list, but no typed action or fixture exists"),
        .init(id: "pinch_zoom", tool: nil, variant: nil, target: .element, api: "-[XCUIElement pinchWithScale:velocity:] (SDK, unused)", verification: [],
              environments: [], status: .unsupported, limitation: "public API exists; the SDK says absolute accuracy is not guaranteed; not modeled"),
        .init(id: "rotate_gesture", tool: nil, variant: nil, target: .element, api: "-[XCUIElement rotate:withVelocity:] (SDK, unused)", verification: [],
              environments: [], status: .unsupported, limitation: "public API exists; best-effort synthesis per the SDK; not modeled"),
        .init(id: "text_selection", tool: nil, variant: nil, target: .element, api: "-", verification: [],
              environments: [], status: .platformLimitation, limitation: "no public XCUIElement API selects a text range deterministically"),
        .init(id: "system_alert", tool: nil, variant: nil, target: .application, api: "-", verification: [],
              environments: [], status: .platformLimitation, limitation: "system alerts belong to SpringBoard, not the app under test; not reachable through the app-scoped typed runner"),
        .init(id: "coordinate_tap", tool: nil, variant: nil, target: .none, api: "-", verification: [],
              environments: [], status: .unsupported, limitation: "deliberately not offered: no raw coordinate execution"),
    ]

    public static func capability(id: String) -> IOSCapability? { all.first { $0.id == id } }

    /// The capability a catalog tool (and its trusted variant, such as a scroll direction) is.
    public static func capability(tool: String, variant: String? = nil) -> IOSCapability? {
        all.first { $0.tool == tool && $0.variant == variant } ?? all.first { $0.tool == tool && $0.variant == nil }
    }

    /// Whether the trusted pipeline accepts `tool` (with `variant`) in `environment`. Unknown means no.
    public static func supports(tool: String, variant: String? = nil, in environment: ExecutionEnvironmentKind) -> Bool {
        capability(tool: tool, variant: variant)?.environments.contains(environment) ?? false
    }
}
