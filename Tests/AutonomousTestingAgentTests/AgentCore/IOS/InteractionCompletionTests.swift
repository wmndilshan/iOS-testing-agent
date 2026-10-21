import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition
@testable import CodeIntelligence

/// Application identity contract: only an explicitly expected, foreground application observed by *this* run is accepted.
@Suite("Application identity contract")
struct ApplicationIdentityContractTests {
    static let bundle = "com.autonomous.agent.fixture"
    static let run = "RUN-1"






}

/// The expected identity travels as typed configuration from the host to the UI test process, and nothing ambient can replace it.
@Suite("Environment propagation")
struct EnvironmentPropagationTests {




}

/// The typed semantic tools and the slow-velocity scroll: catalog, decoding, mock execution and refusal paths.
@Suite("Typed capability completion")
struct TypedCapabilityCompletionTests {
    @Test func testTheNewToolsAreMutatingApprovedAndUseSnapshotElementTargets() throws {
        for name in ["navigate_back", "select_tab", "dismiss_keyboard"] {
            let d = try #require(ToolCatalog.descriptor(for: name))
            #expect(d.risk == .mutating && d.requiresApproval && d.requiresFreshObservationAfter, Comment(rawValue: name))
            // select_tab was promoted on recorded live runs (65479006, FF1B80BE); the other two have no live evidence.
            // select_tab and dismiss_keyboard were promoted on recorded live runs; navigate_back has none.
            #expect(d.live == (name == "navigate_back" ? .implementedNotLiveVerified : .liveVerified), Comment(rawValue: name))
            #expect(Set(d.input.map(\.name)) == ["snapshotID", "elementID"], "no coordinates, no free-form arguments")
        }
    }

    @Test func testScrollVelocityIsAClosedVocabulary() throws {
        let velocity = try #require(ToolCatalog.descriptor(for: "scroll")?.input.first { $0.name == "velocity" })
        #expect(!velocity.required && Set(velocity.allowedValues ?? []) == ["default", "slow"])
        #expect(GestureVelocity(rawValue: "fast") == nil)
    }

    @Test func testNoGenericGestureCoordinateOrCommandToolExists() {
        let names = ToolCatalog.descriptors.map(\.name)
        for banned in ["perform_gesture", "tap_at_coordinate", "coordinate", "run_command", "shell", "simctl", "execute"] {
            #expect(!names.contains { $0.contains(banned) }, Comment(rawValue: banned))
        }
        for d in ToolCatalog.descriptors { #expect(!d.input.contains { ["x", "y", "point", "coordinate", "command"].contains($0.name) }, Comment(rawValue: d.name)) }
    }

    @Test func testTheMockRecordsASlowScrollDistinctly() async throws {
        let obs = IOSTestSupport.snapshot()
        let driver = SimulatedDriver(currentSnapshot: obs)
        _ = try await IOSTestSupport.executor(driver: driver).execute(.scroll(ScrollAction(snapshotID: obs.snapshotID, containerID: "list", direction: .right, velocity: .slow)),
                                                                   context: IOSActionContext(toolName: "scroll", executionID: "e"))
        let captured = await driver.capturedActions
        #expect(captured.contains { $0.contains("scroll-velocity(slow)") })
    }

    @Test func testFixtureScenariosForTheNewToolsDeclareAPreconditionOnEveryStep() throws {
        let expected: [String: [String]] = ["FIXTURE-BACK-NAVIGATION": ["tap_element", "navigate_back"], "FIXTURE-TAB-SELECTION": ["select_tab", "select_tab"],
                                            "FIXTURE-KEYBOARD-DISMISS": ["tap_element", "dismiss_keyboard"]]
        for (id, tools) in expected {
            let s = try #require(FixtureScenarioCatalog.shared.findScenario(by: id), Comment(rawValue: id))
            #expect(s.steps.map(\.toolName) == tools, Comment(rawValue: id))
            #expect(s.steps.allSatisfy { $0.precondition != nil }, Comment(rawValue: id))
            // Each step's precondition is the previous step's postcondition: the chain is checkable on fresh observations.
            #expect(s.steps[1].precondition?.requiredElements == s.steps[0].verification?.requiredElements, Comment(rawValue: id))
        }
    }
}

/// The precondition gate: a step whose trusted precondition does not hold is refused before a proposal or approval exists.
@Suite("Scenario step precondition gate")
@MainActor
struct PreconditionGateTests {
    let controller: ScenarioExecutionController
    let driver: SimulatedDriver
    let registry: ToolRegistry

    static func obs(_ tag: String, status: String) -> Observation {
        let bar = status == "navigation:detail" ? "Detail" : "Root"
        return ProductFixtures.observation(tag, [ProductFixtures.element("bar", role: "navigationBar", identifier: bar, label: nil),
                                                 ProductFixtures.element("back", identifier: nil, label: "Root"),
                                                 ProductFixtures.element("st", role: "staticText", label: status)],
                                           targetBundleID: FixtureScenarioCatalog.bundleID)
    }





}

/// Registry fields requested for every capability, derived so they cannot drift from the catalog or the decoder.
@Suite("Capability registry fields")
struct CapabilityRegistryFieldTests {
    @Test func testApprovalFollowsTheCatalogAndEveryOfferedCapabilityHasAnActionTypeAndEvidenceRequirement() {
        for c in IOSCapabilityRegistry.all {
            guard let tool = c.tool, let d = ToolCatalog.descriptor(for: tool) else {
                #expect(c.actionType == nil && c.evidenceRequirement.isEmpty && c.failureTaxonomy == [.unsupportedCapability], Comment(rawValue: c.id)); continue
            }
            #expect(c.requiresApproval == d.requiresApproval, Comment(rawValue: c.id))
            #expect(c.actionType != nil, Comment(rawValue: c.id))
            if d.risk == .mutating {
                #expect(c.evidenceRequirement.contains("post_observation") && c.evidenceRequirement.contains("application_identity") && c.evidenceRequirement.contains("action_diagnostics"), Comment(rawValue: c.id))
                #expect(!c.verification.isEmpty && c.failureTaxonomy.contains(.verificationFailed), Comment(rawValue: c.id))
            }
        }
    }

    @Test func testTheActionTypeIsWhatTheDecoderProducesForTheTool() throws {
        let obs = IOSTestSupport.snapshot()
        let args: [String: [String: AnyCodableValue]] = [
            "navigate_back": ["snapshotID": .string(obs.snapshotID), "elementID": .string("ok")],
            "select_tab": ["snapshotID": .string(obs.snapshotID), "elementID": .string("ok")],
            "dismiss_keyboard": ["snapshotID": .string(obs.snapshotID), "elementID": .string("field")],
            "scroll": ["snapshotID": .string(obs.snapshotID), "containerID": .string("list"), "direction": .string("right"), "velocity": .string("slow")],
        ]
        for (tool, a) in args {
            let action = try IOSActionDecoder().decode(ToolCall(id: "c", name: tool, arguments: a), bundleID: "b")
            #expect(IOSCapabilityRegistry.all.filter { $0.tool == tool }.allSatisfy { $0.actionType == action.actionType }, Comment(rawValue: tool))
            if case .scroll(let s) = action { #expect(s.velocity == GestureVelocity.slow) }
        }
    }

    @Test func testStatusesFollowTheRecordedLiveEvidence() {
        #expect(IOSCapabilityRegistry.capability(id: "scroll_horizontal_right_slow")?.status == .liveVerified)
        #expect(IOSCapabilityRegistry.capability(id: "tab_selection")?.status == .liveVerified, "both directions, 2026-09-23")
        #expect(IOSCapabilityRegistry.capability(id: "keyboard_dismissal")?.status == .liveVerified, "2/2 with a provisioned keyboard")
        #expect(IOSCapabilityRegistry.capability(id: "swipe")?.status == .intermittent, "one pass, one genuine failure")
        #expect(IOSCapabilityRegistry.capability(id: "back_navigation")?.status == .unitVerified, "no live evidence")
        for id in ["picker", "sheet_or_modal_dismissal", "system_keyboard_key"] { #expect(IOSCapabilityRegistry.capability(id: id)?.status == .failClosed, Comment(rawValue: id)) }
    }
}
