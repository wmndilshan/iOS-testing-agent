import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("simctl client and parser")
struct SimctlClientTests {
    private let json = #"""
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-26-4":[{"udid":"A","name":"iPhone 16","state":"Shutdown","isAvailable":true}],
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
        {"udid":"B","name":"iPhone 17","state":"Booted","isAvailable":true},
        {"udid":"C","name":"iPhone 17 Pro","state":"Booting","isAvailable":false}],
      "com.apple.CoreSimulator.SimRuntime.tvOS-26-0":[{"udid":"T","name":"Apple TV","state":"Shutdown","isAvailable":true}]}}
    """#

    @Test func testParsesIOSDevicesOnly() throws {
        let devices = try SimctlDeviceListParser.parse(Data(json.utf8))
        #expect(devices.map(\.udid).sorted() == ["A", "B", "C"], "tvOS is excluded")
        #expect(devices.first { $0.udid == "B" }?.state == .booted)
        #expect(devices.first { $0.udid == "B" }?.osVersion == "iOS 26.5")
        #expect(devices.first { $0.udid == "C" }?.isAvailable == false)
        #expect(devices.first?.osVersion == "iOS 26.5", "newest runtime first")
    }

    @Test func testRejectsGarbage() {
        #expect(throws: SimulatorError.self) { try SimctlDeviceListParser.parse(Data("nope".utf8)) }
    }

    @Test func testRuntimeVersionFormatting() {
        #expect(SimctlDeviceListParser.osVersion(fromRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4") == "iOS 26.4")
        #expect(SimulatorDeviceState(simctlValue: "Shutting Down") == .shuttingDown)
        #expect(SimulatorDeviceState(simctlValue: "weird") == .unknown)
    }

    @Test func testInvalidArgumentsAreRefusedBeforeAnyProcessRuns() async {
        let client = SimctlSimulatorClient()
        await #expect(throws: SimulatorError.self) { try await client.boot(udid: "x; rm -rf /") }
        await #expect(throws: SimulatorError.self) { try await client.installApp(at: "/tmp/a.zip", udid: "0F0D6B41-9DCA-4D12-A077-F3543AA154F9") }
        await #expect(throws: SimulatorError.self) { try await client.launchApp(bundleID: "bad id", udid: "0F0D6B41-9DCA-4D12-A077-F3543AA154F9") }
    }

    @Test func testBootStateMappingIsNeverAssumed() {
        #expect(SimulatorBootState(deviceState: nil, known: false) == .unknown)
        #expect(SimulatorBootState(deviceState: .booted) == .booted)
        #expect(SimulatorBootState(deviceState: .booted, isAvailable: false) == .unavailable)
        #expect(SimulatorBootState(deviceState: .shutdown) == .shutdown && SimulatorBootState.shutdown.tone == .failure)
    }
}
