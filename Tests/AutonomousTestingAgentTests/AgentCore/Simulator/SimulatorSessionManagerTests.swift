import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Simulator session manager")
struct SimulatorSessionManagerTests {
    let a = FakeSimulatorClient.phoneA.udid
    let b = FakeSimulatorClient.phoneB.udid

    private func make(_ client: FakeSimulatorClient = FakeSimulatorClient()) -> (SimulatorSessionManager, FakeSimulatorClient) {
        (SimulatorSessionManager(client: client, clock: TestClock()), client)
    }

    @Test func testDeviceDiscovery() async throws {
        let (m, _) = make()
        let devices = try await m.refresh()
        #expect(devices.count == 3)
        let name = await m.device(udid: a)?.name
        #expect(name == "iPhone 17")
        #expect(try await m.state(of: a) == .shutdown)
        await #expect(throws: SimulatorError.deviceNotFound("nope")) { try await m.state(of: "nope") }
    }

    @Test func testActivateBootsOnceAndReusesTheSession() async throws {
        let (m, c) = make()
        let first = try await m.activate(udid: a)
        #expect(first.udid == a && first.bootedByApplication)
        let again = try await m.activate(udid: a)
        let third = try await m.activate(udid: a)
        #expect(again == first && third == first, "the same session object is reused across test cases")
        let k = await c.calls()
        #expect(k.boots == [a], "one boot in total, never a second instance")
        #expect(k.shutdowns.isEmpty)
    }

    @Test func testAlreadyBootedDeviceIsAdoptedWithoutBooting() async throws {
        let c = FakeSimulatorClient(); await c.setState(.booted, udid: a)
        let (m, _) = make(c)
        let s = try await m.activate(udid: a)
        #expect(!s.bootedByApplication)
        let beforeDeactivate = await c.calls()
        #expect(beforeDeactivate.boots.isEmpty)
        try await m.deactivate()
        let afterDeactivate = await c.calls()
        #expect(afterDeactivate.shutdowns.isEmpty, "a device the app did not boot is left running")
    }

    @Test func testSwitchingDeviceKeepsExactlyOneManagedInstance() async throws {
        let (m, c) = make()
        _ = try await m.activate(udid: a)
        let second = try await m.activate(udid: b)
        #expect(second.udid == b)
        #expect(await m.session?.udid == b)
        let k = await c.calls()
        #expect(k.shutdowns == [a], "previous app-booted device is shut down")
        let booted = try await m.refresh().filter { $0.state == .booted }
        #expect(booted.map(\.udid) == [b], "exactly one running managed device")
    }

    @Test func testUnavailableAndUnknownDevicesAreRejected() async throws {
        let (m, c) = make()
        await #expect(throws: SimulatorError.deviceUnavailable("iPhone 5")) { try await m.activate(udid: FakeSimulatorClient.broken.udid) }
        await #expect(throws: SimulatorError.deviceNotFound("zzz")) { try await m.activate(udid: "zzz") }
        let session = await m.session
        let k = await c.calls()
        #expect(session == nil && k.boots.isEmpty)
    }

    @Test func testBootFailureLeavesNoSession() async throws {
        let (m, c) = make()
        await c.failBoot(with: .commandFailed("boom"))
        await #expect(throws: SimulatorError.commandFailed("boom")) { try await m.activate(udid: a) }
        let session = await m.session
        #expect(session == nil)
    }

    @Test func testAppOperationsRequireABootedActiveSession() async throws {
        let (m, c) = make()
        await #expect(throws: SimulatorError.noActiveSession) { try await m.launchApp(bundleID: "com.apple.mobilesafari") }
        _ = try await m.activate(udid: a)
        try await m.installApp(at: "/tmp/Some.app")
        try await m.launchApp(bundleID: "com.apple.mobilesafari")
        let k = await c.calls()
        #expect(k.installs == 1 && k.launchUDIDs.first == a)
        await #expect(throws: SimulatorError.self) { try await m.installApp(at: "/tmp/notanapp.zip") }
        await #expect(throws: SimulatorError.self) { try await m.launchApp(bundleID: "not a bundle id; rm -rf") }
        await c.setState(.shutdown, udid: a) // shut down outside the session
        await #expect(throws: SimulatorError.notBooted("iPhone 17")) { try await m.launchApp(bundleID: "com.apple.mobilesafari") }
    }

    @Test func testShutdownEndsTheSession() async throws {
        let (m, c) = make()
        _ = try await m.activate(udid: a)
        try await m.shutdownActiveDevice()
        let session = await m.session
        let k = await c.calls()
        #expect(session == nil && k.shutdowns == [a])
        await #expect(throws: SimulatorError.noActiveSession) { try await m.shutdownActiveDevice() }
    }

    @Test func testBundleIdentifierValidation() {
        #expect(SimulatorSessionManager.isValidBundleID("com.apple.mobilesafari"))
        #expect(!SimulatorSessionManager.isValidBundleID("com"))
        #expect(!SimulatorSessionManager.isValidBundleID("com.x; rm -rf /"))
    }
}
