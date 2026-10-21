import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Simulator target resolver")
struct SimulatorTargetResolverTests {
    private let a = FakeSimulatorClient.phoneA   // the configured device in these tests
    private let b = FakeSimulatorClient.phoneB
    private var preferred: SimulatorTarget { SimulatorTarget(name: a.name, osVersion: a.osVersion, udid: a.udid, bundleID: "com.apple.mobilesafari", previewBundleID: "com.example.preview") }

    @Test("The configured device is used when it is booted")
    func configuredBooted() async {
        let fake = FakeSimulatorClient(devices: [a.with(state: .booted), b.with(state: .booted)])
        let result = await SimulatorTargetResolver.resolve(preferred: preferred, manager: fake)
        #expect(result.target == preferred)
        #expect(await fake.calls().boots.isEmpty)
    }

    @Test("Another booted iPhone is used when the configured one is shut down, keeping the app ids")
    func otherBooted() async {
        let fake = FakeSimulatorClient(devices: [a, b.with(state: .booted)])
        let result = await SimulatorTargetResolver.resolve(preferred: preferred, manager: fake)
        #expect(result.target.udid == b.udid && result.target.name == "iPhone 17 Pro")
        #expect(result.target.bundleID == "com.apple.mobilesafari" && result.target.previewBundleID == "com.example.preview")
        #expect(result.note.contains("not running"))
        #expect(await fake.calls().boots.isEmpty, "a running simulator is never restarted")
    }

    @Test("With nothing running, the configured device is booted and awaited")
    func bootsConfigured() async {
        let fake = FakeSimulatorClient(devices: [a, b])
        let result = await SimulatorTargetResolver.resolve(preferred: preferred, manager: fake)
        #expect(result.target == preferred)
        #expect(await fake.calls().boots == [a.udid])
        #expect(await fake.awaitCalls == [a.udid])
    }

    @Test("If the configured device does not exist, the newest available iPhone is booted; unavailable devices are never chosen")
    func bootsAnother() async {
        let fake = FakeSimulatorClient(devices: [FakeSimulatorClient.broken, b])
        let result = await SimulatorTargetResolver.resolve(preferred: preferred, manager: fake)
        #expect(result.target.udid == b.udid)
        #expect(await fake.calls().boots == [b.udid])
    }

    @Test("When nothing can be booted the configured target is returned, with a note saying so")
    func nothingWorks() async {
        let fake = FakeSimulatorClient(devices: [a])
        await fake.failBoot(with: .commandFailed("no"))
        let result = await SimulatorTargetResolver.resolve(preferred: preferred, manager: fake)
        #expect(result.target == preferred && result.note.contains("could not be started"))
    }
}
