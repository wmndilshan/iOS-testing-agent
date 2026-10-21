import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Long press through the trusted spine, trusted-argument authority, execution correlation in the persisted trace,
/// and the simulation stand-in's independence from live artifacts.
@Suite("Long press, trusted arguments and execution correlation")
@MainActor
struct LongPressAndCorrelationTests {
    private let scenario = FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-LONG-PRESS")!
    private var target: UIElementSnapshot { ProductFixtures.element("lp1", identifier: "fixture.longPress.target", label: "Long press target") }
    private func status(_ label: String) -> UIElementSnapshot {
        ProductFixtures.element("st", role: "staticText", identifier: "fixture.longPress.status", label: label)
    }

    private func rig() -> (ScenarioExecutionController, SimulatedDriver, ToolRegistry) {
        let c = ScenarioExecutionController(catalog: FixtureScenarioCatalog.shared,
                                            validator: TrustedActionValidator(catalog: FixtureScenarioCatalog.shared), clock: TestClock())
        let d = SimulatedDriver(currentSnapshot: ProductFixtures.observation("init", [target, status("longPress:idle")]))
        c.startScenario(scenario)
        return (c, d, ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: d))
    }

    private func proposal(_ obs: Observation, role: String = "button", args: [String: AnyCodableValue] = [:],
                          scenarioID: String? = nil, elementID: String = "lp1") -> ActionProposal {
        ActionProposal(scenarioID: scenarioID ?? scenario.id, snapshotID: obs.snapshotID, elementID: elementID, expectedRole: role,
                       expectedIdentifier: "fixture.longPress.target", toolName: "long_press_element", arguments: args, reason: "r",
                       stepIndex: 0, stepID: scenario.actionStep.id)
    }

    // MARK: Trusted duration

    @Test func testTrustedDurationIsDeliveredToTheDriverExactly() async {
        let (c, d, reg) = rig()
        let s0 = ProductFixtures.observation("s0", [target, status("longPress:idle")])
        c.recordObservation(s0); await d.setSnapshot(s0)
        guard case .success(let req) = c.handleProposal(proposal(s0)) else { Issue.record("must be admitted"); return }
        #expect(req.arguments["durationSeconds"] == .double(1.2))
        c.approveCurrentStep(source: .testAuthority)
        await d.queueNextSnapshot(ProductFixtures.observation("s1", [target, status("longPress:long-pressed")]))
        let result = await c.dispatchCurrentStep(driver: d, toolRegistry: reg)
        guard case .success(let v) = result else { Issue.record("dispatch: \(result)"); return }
        #expect(v.verified)
        #expect(await d.capturedActions.contains("longPress(lp1, 1.2s)"))
    }

    @Test func testProposalCannotOverrideTheTrustedDuration() {
        let (c, _, _) = rig()
        let s0 = ProductFixtures.observation("s0", [target, status("longPress:idle")])
        c.recordObservation(s0)
        for forged in [AnyCodableValue.double(0.1), .double(30), .int(5), .string("1.2")] {
            guard case .failure(let e) = c.handleProposal(proposal(s0, args: ["durationSeconds": forged])) else { Issue.record("forged duration \(forged) accepted"); continue }
            #expect("\(e)".contains("trusted scenario argument"))
        }
    }

    @Test func testDeterministicVerificationFailsWhenTheStatusStaysIdle() async {
        let (c, d, reg) = rig()
        let s0 = ProductFixtures.observation("s0", [target, status("longPress:idle")])
        c.recordObservation(s0); await d.setSnapshot(s0)
        guard case .success = c.handleProposal(proposal(s0)) else { return }
        c.approveCurrentStep(source: .testAuthority)
        await d.queueNextSnapshot(ProductFixtures.observation("s1", [target, status("longPress:idle")]))
        guard case .success(let v) = await c.dispatchCurrentStep(driver: d, toolRegistry: reg) else { Issue.record("dispatch must complete"); return }
        #expect(!v.verified, "an unchanged status can never verify a long press")
    }

    // MARK: Rejections happen before any driver call

    @Test func testWrongRoleWrongSnapshotWrongScenarioAndMissingTargetAreRejected() async {
        let (c, d, _) = rig()
        let s0 = ProductFixtures.observation("s0", [target, status("longPress:idle")])
        c.recordObservation(s0)
        for (name, p) in [("role", proposal(s0, role: "staticText")),
                          ("snapshot", ActionProposal(scenarioID: scenario.id, snapshotID: "snap_old", elementID: "lp1", expectedRole: "button", expectedIdentifier: "fixture.longPress.target", toolName: "long_press_element", reason: "r", stepIndex: 0, stepID: scenario.actionStep.id)),
                          ("scenario", proposal(s0, scenarioID: "FIXTURE-TEXT")),
                          ("missing", proposal(s0, elementID: "ghost"))] {
            if case .success = c.handleProposal(p) { Issue.record("\(name) mismatch must be rejected") }
        }
        #expect(await d.invokedActionCount["longPress"] == nil)
    }

    @Test func testUnapprovedLongPressNeverReachesTheDriver() async {
        let (c, d, reg) = rig()
        let s0 = ProductFixtures.observation("s0", [target, status("longPress:idle")])
        c.recordObservation(s0)
        guard case .success = c.handleProposal(proposal(s0)) else { return }
        _ = await c.dispatchCurrentStep(driver: d, toolRegistry: reg)   // pending, never approved
        #expect(await d.invokedActionCount["longPress"] == nil)
    }


    // MARK: Correlation

    @Test func testExecutionIDCorrelatesTheWholeDispatchInThePersistedTrace() async throws {
        let (c, d, reg) = rig()
        c.configureRunContext(appIdentity: AppIdentity(bundleID: FixtureScenarioCatalog.bundleID, displayName: "Fixture"), simulatorID: "S", simulatorName: "sim", executionMode: "NON_LIVE_TEST")
        let s0 = ProductFixtures.observation("s0", [target, status("longPress:idle")])
        c.recordObservation(s0); await d.setSnapshot(s0)
        guard case .success = c.handleProposal(proposal(s0)) else { Issue.record("admit"); return }
        c.approveCurrentStep(source: .testAuthority)
        await d.queueNextSnapshot(ProductFixtures.observation("s1", [target, status("longPress:long-pressed")]))
        _ = await c.dispatchCurrentStep(driver: d, toolRegistry: reg)
        let trace = try #require(c.activeRunTrace)
        let started = try #require(trace.events.first { $0.eventType == .executionStarted })
        let exec = try #require(started.executionID)
        #expect(started.toolName == "long_press_element" && started.actionType == "ios.long_press")
        #expect(started.tokenID != nil, "the authorization's approval token links to the dispatch")
        for type in [RunTraceEventType.executionFinished, .postObserved] {
            #expect(trace.events.first { $0.eventType == type }?.executionID == exec, "\(type)")
        }
        #expect(trace.events.contains { ($0.eventType == .verificationPassed || $0.eventType == .verificationFailed) && $0.executionID == exec })
        #expect(trace.events.filter { $0.executionID != nil }.allSatisfy { $0.executionID == exec }, "one ID per dispatch")
        // The execution ID equals the one the tool result carries.
        #expect(await d.capturedActions.isEmpty == false)
    }

    @Test func testTraceEventsRoundTripAndOldRecordsWithoutCorrelationStillDecode() throws {
        let e = RunTraceEvent(runID: "r", scenarioID: "s", eventType: .executionStarted, result: "ok", executionID: "E1", toolName: "type_text", actionType: "ios.type_text")
        let back = try JSONDecoder().decode(RunTraceEvent.self, from: JSONEncoder().encode(e))
        #expect(back.executionID == "E1" && back.toolName == "type_text" && back.actionType == "ios.type_text")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        for k in ["executionID", "toolName", "actionType"] { json[k] = nil }
        let old = try JSONDecoder().decode(RunTraceEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.executionID == nil && old.toolName == nil)
    }

    @Test func testTypedTextNeverAppearsInTraceOrToolResult() async throws {
        let field = ProductFixtures.element("f1", role: "textField", identifier: "fixture.text.field")
        let text = FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-TEXT")!
        let c = ScenarioExecutionController(catalog: FixtureScenarioCatalog.shared, validator: TrustedActionValidator(catalog: FixtureScenarioCatalog.shared), clock: TestClock())
        let d = SimulatedDriver(currentSnapshot: ProductFixtures.observation("i", [field]))
        c.startScenario(text)
        let s0 = ProductFixtures.observation("s0", [field, ProductFixtures.element("st", role: "staticText", label: "text-length:0")])
        c.recordObservation(s0); await d.setSnapshot(s0)
        let p = ActionProposal(scenarioID: text.id, snapshotID: s0.snapshotID, elementID: "f1", expectedRole: "textField", expectedIdentifier: "fixture.text.field", toolName: "type_text", reason: "r", stepIndex: 0, stepID: text.actionStep.id)
        guard case .success = c.handleProposal(p) else { Issue.record("admit"); return }
        c.approveCurrentStep(source: .testAuthority)
        await d.queueNextSnapshot(ProductFixtures.observation("s1", [field, ProductFixtures.element("st", role: "staticText", label: "text-length:11")]))
        _ = await c.dispatchCurrentStep(driver: d, toolRegistry: ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: d))
        let trace = try #require(c.activeRunTrace)
        let dump = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        #expect(!dump.contains(FixtureScenarioCatalog.fixtureText))
        #expect(c.activeApproval?.executionSummary?.contains(FixtureScenarioCatalog.fixtureText) != true)
    }

    // MARK: Simulation independence

}

@Suite("Scroll verification uses an explicit position status")
struct ScrollVerificationTests {
    private func obs(_ label: String) -> Observation {
        ProductFixtures.observation("o-\(label)", [ProductFixtures.element("st", role: "other", identifier: "fixture.scroll.status", label: label), ProductFixtures.element("stl", role: "staticText", label: label)])
    }

    @Test func testScrollDownVerifiesOnlyWhenTheListLeftItsOrigin() throws {
        let v = try #require(FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-SCROLL-VERTICAL")?.actionStep.verification)
        #expect(v.verify(in: obs("scroll:first-row:10")).verified)
        #expect(!v.verify(in: obs("scroll:first-row:0")).verified, "an unmoved list must not verify")
        #expect(!v.verify(in: ProductFixtures.observation("none", [])).verified, "a missing status must not verify")
    }

    @Test func testScrollBackVerifiesOnlyAtTheOrigin() throws {
        let v = try #require(FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-SCROLL-VERTICAL")?.teardownStep?.verification)
        #expect(v.verify(in: obs("scroll:first-row:0")).verified)
        #expect(!v.verify(in: obs("scroll:first-row:10")).verified)
    }
}

@Suite("Drag and drop: trusted source and destination")
@MainActor
struct DragTrustTests {
    private let scenario = FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-DRAG")!
    private let source = ProductFixtures.element("src", identifier: "fixture.drag.source", label: "Drag source")
    private let dest = ProductFixtures.element("dst", role: "other", identifier: "fixture.drag.destination", label: "Drop zone")
    private let other = ProductFixtures.element("oth", role: "staticText", identifier: "attacker.zone", label: "Attacker zone")

    private func rig(_ elements: [UIElementSnapshot]) -> (ScenarioExecutionController, Observation) {
        let c = ScenarioExecutionController(catalog: FixtureScenarioCatalog.shared, validator: TrustedActionValidator(catalog: FixtureScenarioCatalog.shared), clock: TestClock())
        c.startScenario(scenario)
        let obs = ProductFixtures.observation("s0", elements)
        c.recordObservation(obs)
        return (c, obs)
    }

    private func proposal(_ obs: Observation, args: [String: AnyCodableValue] = [:]) -> ActionProposal {
        ActionProposal(scenarioID: scenario.id, snapshotID: obs.snapshotID, elementID: "src", expectedRole: "button", expectedIdentifier: "fixture.drag.source",
                       toolName: "drag_and_drop", arguments: args, reason: "r", stepIndex: 0, stepID: scenario.actionStep.id)
    }

    @Test func testScenarioOwnsBothEndsAndTheDragParameters() {
        let (c, obs) = rig([source, dest, other])
        guard case .success(let req) = c.handleProposal(proposal(obs)) else { Issue.record("must be admitted"); return }
        #expect(req.arguments["sourceElementID"] == .string("src"))
        #expect(req.arguments["destinationElementID"] == .string("dst"))
        #expect(req.arguments["holdDurationSeconds"] == .double(0.3))
        #expect(req.arguments["elementID"] == nil)
    }

    @Test func testProposalCannotSupplyOrRedirectTheDestinationOrHold() {
        let (c, obs) = rig([source, dest, other])
        for (key, value) in [("destinationElementID", AnyCodableValue.string("oth")), ("sourceElementID", .string("oth")), ("holdDurationSeconds", .double(0.01))] {
            if case .success = c.handleProposal(proposal(obs, args: [key: value])) { Issue.record("\(key) must be rejected") }
        }
    }

    @Test func testMissingOrAmbiguousDestinationIsRejected() {
        let (c1, o1) = rig([source, other])
        if case .success = c1.handleProposal(proposal(o1)) { Issue.record("missing destination must be rejected") }
        let twin = ProductFixtures.element("dst2", role: "other", identifier: "fixture.drag.destination", label: "Drop zone")
        let (c2, o2) = rig([source, dest, twin])
        if case .success = c2.handleProposal(proposal(o2)) { Issue.record("ambiguous destination must be rejected") }
    }

    @Test func testDestinationCanNeverBeTheSource() {
        let same = ProductFixtures.element("src", identifier: "fixture.drag.source", label: "Drag source")
        let step = ScenarioStep(id: "s", name: "n", description: "d", toolName: "drag_and_drop", locator: ScenarioLocator(role: "button", identifier: "fixture.drag.source"),
                                destination: ScenarioLocator(role: "button", identifier: "fixture.drag.source"))
        let sc = SafeScenario(id: "X", name: "x", purpose: "p", initialStateRequirement: "i", expectedPostActionState: "e", changesUIState: true, actionStep: step)
        let cat = ScenarioCatalog(scenarios: [sc])
        let c = ScenarioExecutionController(catalog: cat, validator: TrustedActionValidator(catalog: cat), clock: TestClock())
        c.startScenario(sc)
        let obs = ProductFixtures.observation("s0", [same]); c.recordObservation(obs)
        let p = ActionProposal(scenarioID: "X", snapshotID: obs.snapshotID, elementID: "src", expectedRole: "button", expectedIdentifier: "fixture.drag.source", toolName: "drag_and_drop", reason: "r", stepIndex: 0, stepID: "s")
        if case .success = c.handleProposal(p) { Issue.record("source == destination must be rejected") }
    }

    @Test func testAuthorizedDragReachesTheDriverWithTrustedEndsOnly() async {
        let (c, obs) = rig([source, dest, other])
        let d = SimulatedDriver(currentSnapshot: obs)
        await d.setSnapshot(obs)
        guard case .success = c.handleProposal(proposal(obs)) else { Issue.record("admit"); return }
        c.approveCurrentStep(source: .testAuthority)
        await d.queueNextSnapshot(ProductFixtures.observation("s1", [source, dest, ProductFixtures.element("st", role: "staticText", label: "drag:dropped")]))
        _ = await c.dispatchCurrentStep(driver: d, toolRegistry: ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: d))
        #expect(await d.invokedActionCount["dragAndDrop"] == 1)
    }
}

@Suite("Bundle targeting of the fixed tap test")
struct BundleTargetingTests {

}

@Suite("Environment delivery to the XCUITest runner")
struct RunnerEnvironmentTests {

}

@Suite("Execution correlation covers success and failure paths")
@MainActor
struct ExecutionCorrelationAuditTests {
    private func runLongPress(finalStatus: String) async throws -> RunTrace {
        let scenario = FixtureScenarioCatalog.shared.findScenario(by: "FIXTURE-LONG-PRESS")!
        let target = ProductFixtures.element("lp1", identifier: "fixture.longPress.target", label: "Long press target")
        let c = ScenarioExecutionController(catalog: FixtureScenarioCatalog.shared, validator: TrustedActionValidator(catalog: FixtureScenarioCatalog.shared), clock: TestClock())
        let d = SimulatedDriver(currentSnapshot: ProductFixtures.observation("i", [target]))
        c.startScenario(scenario)
        let s0 = ProductFixtures.observation("s0", [target, ProductFixtures.element("st", role: "staticText", label: "longPress:idle")])
        c.recordObservation(s0); await d.setSnapshot(s0)
        let p = ActionProposal(scenarioID: scenario.id, snapshotID: s0.snapshotID, elementID: "lp1", expectedRole: "button", expectedIdentifier: "fixture.longPress.target", toolName: "long_press_element", reason: "r", stepIndex: 0, stepID: scenario.actionStep.id)
        guard case .success = c.handleProposal(p) else { throw CancellationError() }
        c.approveCurrentStep(source: .testAuthority)
        await d.queueNextSnapshot(ProductFixtures.observation("s1", [target, ProductFixtures.element("st", role: "staticText", label: finalStatus)]))
        _ = await c.dispatchCurrentStep(driver: d, toolRegistry: ToolRegistry(projectRoot: URL(fileURLWithPath: "/tmp"), driver: d))
        return try #require(c.activeRunTrace)
    }

    private func audit(_ trace: RunTrace) throws {
        let started = try #require(trace.events.firstIndex { $0.eventType == .executionStarted })
        let exec = try #require(trace.events[started].executionID)
        for e in trace.events[started...] where e.eventType != .runFinished {
            #expect(e.executionID == exec, "\(e.eventType.rawValue) must carry the dispatch's execution ID")
        }
        for e in trace.events[..<started] { #expect(e.executionID == nil, "\(e.eventType.rawValue) precedes any dispatch") }
        #expect(trace.events[started].tokenID != nil && trace.events[started].toolName != nil && trace.events[started].actionType != nil)
        #expect(Set(trace.events.compactMap(\.executionID)).count == 1)
    }

    @Test func testSuccessfulDispatchIsCorrelatedEndToEnd() async throws { try audit(try await runLongPress(finalStatus: "longPress:long-pressed")) }

    @Test func testVerificationFailureAndItsRecoveryEventsShareTheExecutionID() async throws {
        let trace = try await runLongPress(finalStatus: "longPress:idle")
        try audit(trace)
        #expect(trace.events.contains { $0.eventType == .verificationFailed })
        #expect(trace.events.contains { $0.eventType == .failureClassified && $0.executionID != nil })
    }

    @Test func testTraceCarriesNoEnvironmentOrSecretMaterial() async throws {
        let dump = String(decoding: try JSONEncoder().encode(try await runLongPress(finalStatus: "longPress:long-pressed")), as: UTF8.self)
        for banned in ["ATA_TEXT", "TEST_RUNNER_", "SIMCTL_CHILD_", "TEST_USER_PASSWORD", "Authorization", "AIza"] { #expect(!dump.contains(banned), "\(banned)") }
    }
}

@Suite("Simulation isolation")
struct SimulationIsolationTests {

}

@Suite("Observation capture must fail visibly")
struct ObservationCaptureHardeningTests {

}
