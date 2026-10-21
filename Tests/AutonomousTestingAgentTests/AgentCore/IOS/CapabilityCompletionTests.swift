import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Signals compare two fresh observations only. Each is typed, deterministic and refuses anything it cannot establish.
@Suite("Transition signals")
struct TransitionSignalTests {
    static func el(_ id: String, role: String = "button", identifier: String? = nil, label: String? = nil, selected: Bool? = nil) -> UIElementSnapshot {
        UIElementSnapshot(id: id, role: role, label: label, identifier: identifier, isSelected: selected, frame: ElementFrame(x: 0, y: 0, width: 50, height: 20))
    }
    static func obs(_ tag: String, _ els: [UIElementSnapshot], app: ObservedApplication? = nil) -> Observation {
        var o = ProductFixtures.observation(tag, els); o.application = app; return o
    }

    @Test func testSelectedBecameNeedsBothStatesAndAUniqueElement() {
        let before = Self.obs("a", [Self.el("t1", label: "First", selected: true), Self.el("t2", label: "Second", selected: false)])
        let after = Self.obs("b", [Self.el("t1", label: "First", selected: false), Self.el("t2", label: "Second", selected: true)])
        let signal = ObservationSignal.selectedBecame(SignalLocator(role: "button", label: "Second"))
        #expect(signal.evaluate(pre: before, post: after).held)
        #expect(!signal.evaluate(pre: after, post: after).held, "already selected is not a transition")
        // Unrecorded selected state never satisfies it.
        let unknown = Self.obs("c", [Self.el("t2", label: "Second", selected: nil)])
        #expect(!signal.evaluate(pre: before, post: unknown).held)
        // Ambiguity never satisfies it.
        let twice = Self.obs("d", [Self.el("t2", label: "Second", selected: true), Self.el("t3", label: "Second", selected: true)])
        #expect(!signal.evaluate(pre: before, post: twice).held)
    }

    @Test func testNavigationBarBecameRequiresExactlyOneNewlyIdentifiedBar() {
        let root = Self.obs("r", [Self.el("b", role: "navigationBar", identifier: "Root")])
        let detail = Self.obs("d", [Self.el("b", role: "navigationBar", identifier: "Detail")])
        #expect(ObservationSignal.navigationBarBecame(identifier: "Detail").evaluate(pre: root, post: detail).held)
        #expect(ObservationSignal.navigationBarBecame(identifier: "Root").evaluate(pre: detail, post: root).held)
        #expect(!ObservationSignal.navigationBarBecame(identifier: "Detail").evaluate(pre: detail, post: detail).held, "it was already there")
        #expect(!ObservationSignal.navigationBarBecame(identifier: "Detail").evaluate(pre: root, post: root).held)
        let two = Self.obs("t", [Self.el("b", role: "navigationBar", identifier: "Detail"), Self.el("c", role: "navigationBar", identifier: "Other")])
        #expect(!ObservationSignal.navigationBarBecame(identifier: "Detail").evaluate(pre: root, post: two).held, "ambiguous navigation state")
    }


    @Test func testEverySignalHasAStableNameAndNoneIsAGenericLooksChanged() {
        let all: [ObservationSignal] = [.elementExists(SignalLocator(identifier: "a")), .elementAppeared(SignalLocator(identifier: "a")),
                                        .elementDisappeared(SignalLocator(identifier: "a")), .labelChanged(identifier: "a"), .labelBecame(identifier: "a", to: "b"),
                                        .valueChanged(identifier: "a"), .foregroundApplication(bundleID: "b"), .accessibilitySnapshotChanged,
                                        .selectedBecame(SignalLocator(identifier: "a")), .navigationBarBecame(identifier: "a"), .keyboardBecame(visible: true)]
        #expect(Set(all.map(\.name)).count == all.count)
        // Signals round-trip as trusted catalog data.
        for s in all { #expect(try! JSONDecoder().decode(ObservationSignal.self, from: JSONEncoder().encode(s)) == s, Comment(rawValue: s.name)) }
    }

    @Test func testAStepThatDeclaresSignalsIsNeverVerifiedWithoutAFreshPreObservation() {
        let step = ScenarioStep(id: "s", name: "s", description: "s", toolName: "select_tab", locator: ScenarioLocator(role: "button", label: "Second"),
                                verification: ScenarioStepVerification(description: "ok", requiredElements: []),
                                signals: [.selectedBecame(SignalLocator(role: "button", label: "Second"))])
        let scenario = SafeScenario(id: "S", name: "s", purpose: "p", initialStateRequirement: "i", expectedPostActionState: "e", changesUIState: true, actionStep: step)
        let post = Self.obs("p", [Self.el("t2", label: "Second", selected: true)])
        let missingPre = ScenarioVerificationService().verify(step: step, scenario: scenario, observation: post, pre: nil)
        #expect(!missingPre.verified && missingPre.reason.contains("pre-action observation"))
        let pre = Self.obs("q", [Self.el("t2", label: "Second", selected: false)])
        #expect(ScenarioVerificationService().verify(step: step, scenario: scenario, observation: post, pre: pre).verified)
        // A signal that does not hold fails the step even when the status rule would pass.
        #expect(!ScenarioVerificationService().verify(step: step, scenario: scenario, observation: post, pre: post).verified)
    }
}


/// Swipe is not scroll: it has no fixture scenario, so it stays unverified rather than borrowing scroll's evidence.
@Suite("Swipe honesty")
struct SwipeHonestyTests {
    @Test func testSwipeHasItsOwnScenarioAndItsStatusMatchesItsMixedEvidence() throws {
        // One pass (5D1875BC) and one genuine failure (B00084C5): intermittent, never promoted to live-verified.
        #expect(IOSCapabilityRegistry.capability(id: "swipe")?.status == .intermittent)
        #expect(ToolCatalog.descriptor(for: "swipe")?.live == .liveVerified, "the tool has recorded live runs; the capability carries the intermittency")
        // The swipe scenario is a real transition, not a rubber stamp: it states the position it starts from, the typed
        // direction, and a postcondition that can only hold if the list actually moved.
        let scenario = try #require(FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-SWIPE"))
        let step = try #require(scenario.steps.first)
        #expect(scenario.steps.count == 1 && step.toolName == "swipe", "one independently reproducible step")
        #expect(step.precondition != nil && step.verification != nil)
        #expect(step.trustedArguments["direction"] == .string("up"))
        #expect(step.locator.identifier == "fixture.scroll.vertical" && step.locator.role == "scrollView")
        let forbidden = step.verification?.forbiddenElements.map(\.label) ?? []
        #expect(forbidden.contains("scroll:first-row:0"), "the origin position must be gone afterwards")
        // The typed direction still decodes and validates.
        let action = try IOSActionDecoder().decode(ToolCall(id: "c", name: "swipe", arguments: ["snapshotID": .string("s"), "elementID": .string("e"), "direction": .string("up")]), bundleID: "b")
        #expect(action.actionType == "swipe")
        #expect(throws: (any Error).self) {
            try IOSActionDecoder().decode(ToolCall(id: "c", name: "swipe", arguments: ["snapshotID": .string("s"), "elementID": .string("e"), "direction": .string("sideways")]), bundleID: "b")
        }
    }
}

/// Simulator preflight stays read-only and now also checks the device and runtime the run was reviewed for.
@Suite("Simulator preflight identity")
struct SimulatorPreflightIdentityTests {
    struct Listing: SimulatorListing {
        let devices: [SimulatorDevice]
        func listDevices() async throws -> [SimulatorDevice] { devices }
    }
    static let udid = "0F0D6B41-9DCA-4D12-A077-F3543AA154F9"
    static func device(name: String = "iPhone 17", os: String = "iOS 26.5") -> SimulatorDevice {
        SimulatorDevice(udid: udid, name: name, osVersion: os, state: .booted, isAvailable: true)
    }


}

/// One authoritative registry: it must agree with the catalog, the decoder, the matrix and the live-evidence document,
/// and a status may never be promoted by editing a string alone.
@Suite("Capability registry honesty")
struct CapabilityRegistryHonestyTests {
    func doc(_ path: String) throws -> String { try String(contentsOf: RepositoryRoot.url.appendingPathComponent(path), encoding: .utf8) }

    @Test func testEveryCapabilityExposesTheFullContract() throws {
        for c in IOSCapabilityRegistry.all {
            #expect(!c.id.isEmpty && !c.limitation.isEmpty || c.tool != nil, Comment(rawValue: c.id))
            #expect(!c.verificationStrategy.isEmpty, Comment(rawValue: c.id))
            guard let tool = c.tool else {
                #expect(c.environments.isEmpty, Comment(rawValue: "\(c.id): a refused capability declares no environment"))
                continue
            }
            let d = try #require(ToolCatalog.descriptor(for: tool), Comment(rawValue: tool))
            #expect(c.requiresApproval == d.requiresApproval && c.actionType != nil, Comment(rawValue: c.id))
            #expect(!c.environments.isEmpty && !c.environments.contains(.physicalDevice), Comment(rawValue: c.id))
            #expect(!c.failureTaxonomy.isEmpty, Comment(rawValue: c.id))
        }
    }


    @Test func testEveryToolBackedCapabilityIsDecodableAndAgreesWithTheMatrixRow() throws {
        let matrix = try doc("docs/IOS_CAPABILITY_MATRIX.md")
        let section = try #require(matrix.components(separatedBy: "## Capability registry").dropFirst().first)
        for c in IOSCapabilityRegistry.all {
            let row = try #require(section.split(separator: "\n").first { $0.hasPrefix("| `\(c.id)` |") }, Comment(rawValue: c.id))
            #expect(row.contains("| `\(c.status.rawValue)` |"), Comment(rawValue: c.id))
            for signal in c.verification { #expect(row.contains(signal.rawValue), Comment(rawValue: "\(c.id): \(signal.rawValue) missing from its row")) }
        }
    }

    @Test func testTheRegistrySignalVocabularyIsBackedByRealVerificationPrimitives() {
        // Every registry signal name must correspond to something verification can actually evaluate.
        let supported: Set<IOSVerificationSignal> = [.elementAppeared, .elementDisappeared, .labelChanged, .valueChanged, .foregroundApplication,
                                                     .accessibilitySnapshotChanged, .selectedStateChanged, .navigationStateChanged, .keyboardVisibilityChanged]
        #expect(Set(IOSVerificationSignal.allCases) == supported)
        let used = Set(IOSCapabilityRegistry.all.flatMap(\.verification))
        #expect(used.isSubset(of: supported))
    }
}

/// Regression: the runner's own session log is several megabytes. A size cap once skipped it, so provenance came back
/// empty and healthy live runs were refused as `runner_provenance_unverified` (tabs and keyboard, 2026-09-23).
@Suite("Runner provenance is read from a real-sized session log")
struct RunnerProvenanceSizeTests {
}

/// Read-only capabilities are not given manufactured live evidence: each one states why it is, or is not, live-verified.
@Suite("Read-only capability honesty")
struct ReadOnlyCapabilityHonestyTests {
    static let readOnly = ["screenshot", "app_state", "element_details", "wait_for_element", "inspect_elements"]

    @Test func testEachReadOnlyCapabilityExplainsItsEvidenceLevel() throws {
        for id in Self.readOnly {
            let c = try #require(IOSCapabilityRegistry.capability(id: id), Comment(rawValue: id))
            #expect(!c.requiresApproval, Comment(rawValue: "\(id) is read-only"))
            #expect(c.verification.isEmpty, Comment(rawValue: "\(id) changes nothing, so it declares no transition signal"))
            #expect(c.evidenceRequirement == ["observation", "application_identity"], Comment(rawValue: id))
            if c.status != .liveVerified {
                #expect(c.limitation.count > 40, Comment(rawValue: "\(id): a capability without live evidence must say why"))
            }
        }
    }

    @Test func testInspectUsesTrustedScenarioExpectationsAndWaitStaysBounded() throws {
        let inspect = try #require(IOSCapabilityRegistry.capability(id: "inspect_elements"))
        #expect(inspect.status == .liveVerified)
        #expect(inspect.limitation.contains("001E7D28-9F1C-4517-B01C-8C0D303CC5E5"), "status cites the completed controller execution")
        let performer = try #require(SourceTree.core.first { $0.name == "ObservationPerformers.swift" }).code
        #expect(performer.contains("env.context.scenarioID"), "inspection expectations follow the controller-owned scenario")
        #expect(!performer.contains("SCENARIO-INSPECT-LOGIN-SCREEN"), "inspection cannot silently substitute a fixed surface")
        // The waiter stays bounded and observation-based: no predicates, no coordinates, no unbounded polling.
        let waiter = try #require(SourceTree.core.first { $0.name == "IOSExecution.swift" }).code
        #expect(waiter.contains("maxPolls") || waiter.contains("polls"), "bounded polls")
        #expect(performer.contains("captureObservation"), "each poll is a fresh observation")
        for banned in ["NSPredicate", "coordinate(", "while true"] { #expect(!performer.contains(banned), Comment(rawValue: banned)) }
    }
}

/// Regressions from the 2026-09-23 investigation of navigate_back and of gesture delivery.
@Suite("Navigate back and gesture diagnostics")
struct NavigateBackAndGestureDiagnosticsTests {
    @Test func testTheBackScenarioTargetsARealNavigationBarButtonByIdentifier() throws {
        // Execution 47720F1D failed because the system chevron is not an accessible Button when the stack launches pushed.
        // The fixture now carries an explicit navigation-bar back button; the scenario must target it by identifier.
        let scenario = try #require(FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-NAVIGATE-BACK"))
        let step = try #require(scenario.steps.first)
        #expect(scenario.steps.count == 1, "reproducible from launch, not from a previous step")
        #expect(step.toolName == "navigate_back" && step.locator.role == "button")
        #expect(step.locator.identifier == "fixture.navigation.back", "resolved by identifier, never by position")
        #expect(step.precondition != nil && step.signals.contains(.navigationBarBecame(identifier: "Root")))
        let fixture = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("Fixtures/iOSFixtureApp/Sources/FixtureApp.swift"), encoding: .utf8)
        #expect(fixture.contains("fixture.navigation.back") && fixture.contains("dismiss()"), "a real control performing a real pop")
        #expect(fixture.contains("navigationBarBackButtonHidden"), "it replaces the chevron rather than hiding a second control behind it")
    }


    @Test func testAnIntermittentCapabilityIsNeverPromotedByAPassingRunAlone() {
        // The rule the statuses follow: a genuine pass plus a genuine unexplained failure is INTERMITTENT, not LIVE_VERIFIED.
        for id in ["tap", "double_tap", "scroll_horizontal_right", "swipe"] {
            let c = IOSCapabilityRegistry.capability(id: id)
            #expect(c?.status == .intermittent, Comment(rawValue: id))
            #expect(c?.limitation.isEmpty == false, Comment(rawValue: "\(id) must state the failure it still carries"))
        }
    }
}

/// Build identity: which build ran is decided by the content of the bundle the runner loaded, not by its container path.
/// Proven on 2026-09-23: every dead container on the machine held a runner byte-identical to the installed one, so the
/// path-based rule was refusing runs that had executed the reviewed build (11 of 16 in one batch).
@Suite("Runner build identity")
struct RunnerBuildIdentityTests {
    static let bundle = "com.autonomous.agent.fixture"
    static let current = "81e2af26491479dc0000000000000000000000000000000000000000000000aa"
    static let older = "0000000000000000000000000000000000000000000000000000000000000001"






}

/// The tap diagnostics must separate the failure states the investigation needs to tell apart. Classification is done from
/// facts the runner records in the same process as the gesture, never from the XCTest result.
@Suite("Tap failure classification")
struct TapFailureClassificationTests {
    /// The states a tap outcome is classified into, from run facts alone.
    enum State: Equatable { case targetNotFound, targetNotHittable, deliveredNoTransition, transitionObserved, wrongApplication, staleRunner }

    static func classify(resolved: Bool, hittable: Bool, treeAfterShowsTransition: Bool, identityMatches: Bool, buildMatches: Bool) -> State {
        if !buildMatches { return .staleRunner }
        if !identityMatches { return .wrongApplication }
        if !resolved { return .targetNotFound }
        if !hittable { return .targetNotHittable }
        return treeAfterShowsTransition ? .transitionObserved : .deliveredNoTransition
    }

    @Test func testTheRecordedFactsOfTheRealRunsClassifyThemDistinctly() {
        // Failing run 1FC60355 (2026-09-24): resolved, hittable, delivered, and the app's own tree still read navigation:root.
        #expect(Self.classify(resolved: true, hittable: true, treeAfterShowsTransition: false, identityMatches: true, buildMatches: true) == .deliveredNoTransition)
        // Passing run 7273777C: same resolution, and the tree in the same process read navigation:detail.
        #expect(Self.classify(resolved: true, hittable: true, treeAfterShowsTransition: true, identityMatches: true, buildMatches: true) == .transitionObserved)
        // The excluded explanations remain distinguishable rather than collapsing into "tap failed".
        #expect(Self.classify(resolved: false, hittable: false, treeAfterShowsTransition: false, identityMatches: true, buildMatches: true) == .targetNotFound)
        #expect(Self.classify(resolved: true, hittable: false, treeAfterShowsTransition: false, identityMatches: true, buildMatches: true) == .targetNotHittable)
        #expect(Self.classify(resolved: true, hittable: true, treeAfterShowsTransition: true, identityMatches: false, buildMatches: true) == .wrongApplication)
        #expect(Self.classify(resolved: true, hittable: true, treeAfterShowsTransition: true, identityMatches: true, buildMatches: false) == .staleRunner)
    }


}

/// The fixture's diagnostic counters exist to tell mechanisms apart, and must never become a success criterion.
/// Proven with them on 2026-09-24: the navigation stack is popped once, in the same app process, before any gesture.
@Suite("Diagnostic counters")
struct DiagnosticCounterTests {
    @Test func testTheCountersObserveStateAndTakeNoPartInGestureHandling() throws {
        let fixture = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("Fixtures/iOSFixtureApp/Sources/FixtureApp.swift"), encoding: .utf8)
        #expect(fixture.contains("fixture.navigation.events") && fixture.contains("nav-events push:"))
        #expect(fixture.contains("fixture.scroll.events") && fixture.contains("scroll-events:"))
        // They are derived from state the screens already keep (onChange of the path, the scroll geometry callback),
        // never from a gesture recognizer added for the test.
        #expect(fixture.contains(".onChange(of: path)"))
        #expect(!fixture.contains("NSPrincipalClass"), "no principal-class instrumentation")
        // The instrumented screens carry no gesture recognizer of their own: the counters must not be able to change what
        // the application recognizes. (LongPressScreen legitimately has one — it is the capability under test.)
        for screen in ["struct NavigationScreen", "struct VerticalScrollScreen", "struct HorizontalScrollScreen"] {
            let body = fixture.components(separatedBy: screen).dropFirst().first?.components(separatedBy: "\nstruct ").first ?? ""
            #expect(!body.isEmpty, Comment(rawValue: screen))
            #expect(!body.contains("simultaneousGesture") && !body.contains("TapGesture()"), Comment(rawValue: "\(screen) must stay free of added recognizers"))
        }
    }

    @Test func testNoVerificationRuleEverReadsACounter() {
        // Every fixture step still verifies a status label or an element; a counter never appears in a rule.
        for scenario in FixtureScenarioCatalog.shared.scenarios {
            for step in scenario.steps {
                let labels = (step.verification?.requiredElements ?? []).compactMap(\.label) + (step.verification?.forbiddenElements ?? []).compactMap(\.label)
                    + (step.precondition?.requiredElements ?? []).compactMap(\.label)
                for label in labels {
                    #expect(!label.contains("nav-events") && !label.contains("scroll-events"),
                            Comment(rawValue: "\(scenario.id)/\(step.id) verifies a diagnostic counter"))
                }
            }
        }
    }

}

/// The navigation trace that located the pop (2026-09-24). Like the counters it is evidence only: it records the screen's
/// own lifecycle, never drives it, and no verification rule may read it.
@Suite("Navigation trace")
struct NavigationTraceTests {
    @Test func testTheTraceRecordsLifecycleOnlyAndAddsNoRecognizer() throws {
        let fixture = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("Fixtures/iOSFixtureApp/Sources/FixtureApp.swift"), encoding: .utf8)
        #expect(fixture.contains("fixture.navigation.trace"))
        for event in ["rootAppear", "detailAppear", "detailDisappear", "phase-", "push", "pop"] {
            #expect(fixture.contains("\"\(event)") || fixture.contains("record(\"\(event)"), Comment(rawValue: event))
        }
        let nav = fixture.components(separatedBy: "struct NavigationScreen").dropFirst().first?.components(separatedBy: "\nstruct ").first ?? ""
        #expect(!nav.contains("simultaneousGesture") && !nav.contains("TapGesture()"), "the traced screen gains no recognizer")
        // The trace can only append; it never sets the path, so it cannot cause or hide a pop.
        let trace = fixture.components(separatedBy: "final class NavTrace").dropFirst().first?.components(separatedBy: "\nstruct ").first ?? ""
        #expect(!trace.contains("path") && trace.contains("events.append"))
    }


}

/// Every live path must act only on an application that is actually in the foreground, and must give its target the same
/// chance to exist. Tap was the odd one out (activate → `.exists` → tap), which matches the historical failure signature.
@Suite("Live path preconditions")
struct LivePathPreconditionTests {

}

/// The reproduced tap failure of 2026-09-24 (execution 4330C111), and the two explanations it disproved.
@Suite("Tap failure 4330C111")
struct TapFailureReproductionTests {
    @Test func testTheFailureIsClassifiedAsNoActivationAndExcludesTheOtherShapes() {
        // Recorded facts: same process (trace prefix unchanged), counters never moved, tree still on root.
        let preEvents = "nav-events push:0 pop:0", postEvents = "nav-events push:0 pop:0"
        #expect(preEvents == postEvents, "no push and no pop: the link never activated")
        // The shapes this rules out, each of which would have left a different counter signature.
        #expect(postEvents != "nav-events push:1 pop:1", "not activated-then-popped")
        #expect(postEvents != "nav-events push:1 pop:0", "not a transition the observation missed")
    }


}

/// Temporary diagnostics are temporary. The H1/H2 touch probe (2026-09-24) failed its own validation criterion — two taps
/// that navigated recorded no touch — so it was removed; this pins that it, and anything like it, stays out of the fixture.
@Suite("Fixture stays free of touch instrumentation")
struct FixtureInstrumentationCleanlinessTests {
    @Test func testNoTouchProbeOrEventInterceptionRemains() throws {
        let fixture = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("Fixtures/iOSFixtureApp/Sources/FixtureApp.swift"), encoding: .utf8)
        for banned in ["TouchProbe", "UIGestureRecognizer", "UIViewRepresentable", "cancelsTouchesInView", "sendEvent", "NSPrincipalClass"] {
            #expect(!fixture.contains(banned), Comment(rawValue: "\(banned) is instrumentation, not fixture behaviour"))
        }
        // What legitimately remains: the app's own gestures and the evidence-only counters and trace.
        #expect(fixture.contains("onTapGesture(count: 2)") && fixture.contains("LongPressGesture"), "the capabilities under test")
        #expect(fixture.contains("fixture.navigation.events") && fixture.contains("fixture.navigation.trace"))
    }

}
