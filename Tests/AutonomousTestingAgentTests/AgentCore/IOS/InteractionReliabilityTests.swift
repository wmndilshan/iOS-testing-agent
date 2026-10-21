import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

/// Application identity: an observation or action of another application is never accepted as the expected one.
@Suite("Application identity")
struct ApplicationIdentityTests {
    static let fixture = "com.autonomous.agent.fixture"



}

/// The application identity and fixture signals through the real controller (mock driver).
@Suite("Application identity through the trusted spine")
@MainActor
struct ApplicationIdentitySpineTests {
    static let product = DriverError.wrongApplication(expected: "com.autonomous.agent.fixture", observed: "com.apple.mobilesafari (source: default, foreground: true)")





}

/// Simulator identity preflight over the typed, read-only listing.
@Suite("Simulator preflight")
struct SimulatorPreflightTests {
    struct Listing: SimulatorManaging {
        let devices: [SimulatorDevice]
        var fails = false
        func listDevices() async throws -> [SimulatorDevice] { if fails { throw SimulatorError.commandFailed("x") }; return devices }
        func boot(udid: String) async throws { Issue.record("preflight must not boot") }
        func awaitBoot(udid: String) async throws { Issue.record("preflight must not wait") }
        func shutdown(udid: String) async throws { Issue.record("preflight must not shut down") }
        func installApp(at path: String, udid: String) async throws { Issue.record("preflight must not install") }
        func launchApp(bundleID: String, udid: String) async throws { Issue.record("preflight must not launch") }
        func terminateApp(bundleID: String, udid: String) async throws { Issue.record("preflight must not terminate") }
    }
    static let udid = "0F0D6B41-9DCA-4D12-A077-F3543AA154F9"
    static func device(_ state: SimulatorDeviceState, available: Bool = true) -> SimulatorDevice {
        SimulatorDevice(udid: udid, name: "iPhone 17", osVersion: "26.5", state: state, isAvailable: available)
    }


}

/// The capability registry agrees with the catalog, declares environments honestly and offers nothing coordinate-based.
@Suite("iOS capability registry")
struct IOSCapabilityRegistryTests {
    @Test func testEveryDeviceToolHasACapabilityAndStatusesAgreeWithTheCatalog() {
        for d in ToolCatalog.descriptors where d.live != .notApplicable {
            let caps = IOSCapabilityRegistry.all.filter { $0.tool == d.name }
            #expect(!caps.isEmpty, Comment(rawValue: d.name))
            for c in caps where c.status == .liveVerified || c.status == .intermittent {
                #expect(d.live == .liveVerified, Comment(rawValue: "\(c.id) claims live evidence but the catalog says \(d.live.rawValue)"))
            }
            if d.live != .liveVerified {
                #expect(caps.allSatisfy { $0.status != .liveVerified && $0.status != .intermittent }, Comment(rawValue: d.name))
            }
        }
        #expect(Set(IOSCapabilityRegistry.all.map(\.id)).count == IOSCapabilityRegistry.all.count, "unique ids")
    }

    @Test func testRefusedCapabilitiesHaveNoToolAndNoEnvironmentAndNothingRunsOnADevice() {
        for c in IOSCapabilityRegistry.all where [.failClosed, .unsupported, .platformLimitation].contains(c.status) {
            #expect(c.tool == nil && c.environments.isEmpty, Comment(rawValue: c.id))
        }
        for c in IOSCapabilityRegistry.all { #expect(!c.environments.contains(.physicalDevice), Comment(rawValue: "\(c.id): no physical-device driver exists")) }
        #expect(!IOSCapabilityRegistry.supports(tool: "double_tap_element", in: .physicalDevice))
        #expect(IOSCapabilityRegistry.supports(tool: "scroll", variant: "right", in: .simulator))
        #expect(!IOSCapabilityRegistry.supports(tool: "tap_at_coordinate", in: .simulator), "unknown tools are refused")
        #expect(IOSCapabilityRegistry.capability(id: "coordinate_tap")?.status == .unsupported)
        // The two unresolved capabilities are not promoted without new evidence.
        #expect(IOSCapabilityRegistry.capability(id: "double_tap")?.status == .intermittent)
        #expect(IOSCapabilityRegistry.capability(id: "scroll_horizontal_right")?.status == .intermittent)
        #expect(IOSCapabilityRegistry.capability(id: "scroll_horizontal_left")?.status == .liveVerified, "SA-E2E-003, 2/2 with complete evidence after the stale-runner fix")
        #expect(IOSCapabilityRegistry.capability(id: "tap")?.status == .intermittent, "74985D87 is unexplained")
    }

    @Test func testTheCapabilityMatrixDocumentsEveryRegistryEntryWithItsStatusAndEnvironment() throws {
        let matrix = try String(contentsOf: RepositoryRoot.url.appendingPathComponent("docs/IOS_CAPABILITY_MATRIX.md"), encoding: .utf8)
        let section = try #require(matrix.components(separatedBy: "## Capability registry").dropFirst().first?.components(separatedBy: "\n## ").first)
        for c in IOSCapabilityRegistry.all {
            let row = try #require(section.split(separator: "\n").first { $0.hasPrefix("| `\(c.id)` |") }, Comment(rawValue: c.id))
            #expect(row.contains("| `\(c.status.rawValue)` |"), Comment(rawValue: "\(c.id): \(row)"))
            #expect(row.contains(c.environments.isEmpty ? "| — |" : "| simulator |"), Comment(rawValue: c.id))
        }
    }

}

/// Reusable verification primitives compare fresh observations, never a driver's report.
@Suite("Observation signals")
struct ObservationSignalTests {
    static func obs(_ elements: [UIElementSnapshot], app: ObservedApplication? = nil) -> Observation {
        var o = ProductFixtures.observation("s", elements); o.application = app; return o
    }
    static func status(_ id: String, _ label: String) -> UIElementSnapshot { ProductFixtures.element(id, role: "staticText", identifier: id, label: label) }

    @Test func testSignalsHoldOnlyForTheRealTransition() {
        let pre = Self.obs([Self.status("fixture.doubleTap.status", "doubleTap:idle")])
        let single = Self.obs([Self.status("fixture.doubleTap.status", "doubleTap:single-tapped")])
        let double = Self.obs([Self.status("fixture.doubleTap.status", "doubleTap:double-tapped")])
        let became = ObservationSignal.labelBecame(identifier: "fixture.doubleTap.status", to: "doubleTap:double-tapped")
        #expect(became.evaluate(pre: pre, post: double).held)
        #expect(!became.evaluate(pre: pre, post: single).held, "a single tap is a change, but not the expected one")
        #expect(!became.evaluate(pre: double, post: double).held, "already true before: not caused by the action")
        #expect(ObservationSignal.labelChanged(identifier: "fixture.doubleTap.status").evaluate(pre: pre, post: single).held)
        let idle = SignalLocator(role: "staticText", label: "doubleTap:idle")
        #expect(ObservationSignal.elementDisappeared(idle).evaluate(pre: pre, post: double).held)
        #expect(!ObservationSignal.elementAppeared(idle).evaluate(pre: pre, post: double).held)
        #expect(ObservationSignal.accessibilitySnapshotChanged.evaluate(pre: pre, post: double).held && !ObservationSignal.accessibilitySnapshotChanged.evaluate(pre: pre, post: pre).held)
    }

    @Test func testAmbiguityAndIdentityFailClosed() {
        let twice = Self.obs([Self.status("fixture.hscroll.status", "a"), Self.status("fixture.hscroll.status", "b")])
        let once = Self.obs([Self.status("fixture.hscroll.status", "c")])
        #expect(!ObservationSignal.labelChanged(identifier: "fixture.hscroll.status").evaluate(pre: twice, post: once).held, "an ambiguous identifier satisfies nothing")
        #expect(!ObservationSignal.elementExists(SignalLocator(identifier: "fixture.hscroll.status")).evaluate(pre: once, post: twice).held)
        let fixture = "com.autonomous.agent.fixture"
        #expect(ObservationSignal.foregroundApplication(bundleID: fixture).evaluate(pre: once, post: Self.obs([], app: ObservedApplication(bundleID: fixture, bundleSource: "environment", foreground: true))).held)
        #expect(!ObservationSignal.foregroundApplication(bundleID: fixture).evaluate(pre: once, post: Self.obs([], app: ObservedApplication(bundleID: "com.apple.mobilesafari", bundleSource: "default", foreground: true))).held)
        #expect(!ObservationSignal.foregroundApplication(bundleID: fixture).evaluate(pre: once, post: once).held, "no identity, no pass")
    }
}
