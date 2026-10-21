import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Simulator pane model")
@MainActor
struct SimulatorPaneModelTests {
    let a = FakeSimulatorClient.phoneA.udid

    private func make(defaults: UserDefaults? = nil) -> (SimulatorPaneModel, FakeSimulatorClient, Counter, UserDefaults) {
        let client = FakeSimulatorClient()
        let counter = Counter()
        let d = defaults ?? UserDefaults(suiteName: "sim-tests-\(UUID().uuidString)")!
        let model = SimulatorPaneModel(manager: SimulatorSessionManager(client: client, clock: TestClock()),
                                       runnerTargetUDID: a, defaults: d, openRealSimulator: { counter.opened += 1 })
        return (model, client, counter, d)
    }

    final class Counter { var opened = 0 }

    @Test func testDiscoveryFillsDevicesAndSelectsRunnerTarget() async {
        let (m, _, _, _) = make()
        await m.refresh()
        #expect(m.devices.count == 3 && m.selectedUDID == a && m.selectedDevice?.name == "iPhone 17")
        #expect(m.bootState == .shutdown && m.lastError == nil)
    }

    @Test func testActivateBootsOnceAndSecondActivationReusesTheSession() async {
        let (m, c, _, _) = make()
        await m.refresh()
        await m.activateSelected(); await m.activateSelected()
        let k = await c.calls()
        #expect(k.boots == [a])
        #expect(m.activeUDID == a && m.isSessionActive && m.bootState == .booted)
    }

    @Test func testDockAndUndockOnlyChangePresentation() async {
        let (m, c, counter, _) = make()
        await m.refresh(); await m.activateSelected()
        let before = await c.calls()
        for _ in 0..<5 { m.undock(); m.dock() }
        m.hide(); m.dock()
        let after = await c.calls()
        #expect(after == before, "docking and undocking cause no boot, shutdown or app call")
        #expect(after.shutdowns.isEmpty)
        #expect(m.activeUDID == a && m.deviceState == .booted, "same session, still booted")
        #expect(counter.opened == 5, "undock only brings the real Simulator.app forward")
        #expect(m.placement == .docked)
        m.undock()
        #expect(m.placement == .realWindow && !m.isSimulatorVisible)
    }

    @Test func testPreviewToggleIsPersistedAndIndependentOfPlacement() async {
        let suite = UserDefaults(suiteName: "sim-tests-\(UUID().uuidString)")!
        let (m, c, _, d) = make(defaults: suite)
        #expect(m.isPreviewEnabled, "on by default")
        #expect(m.shouldStreamPreview)
        m.isPreviewEnabled = false
        #expect(!m.shouldStreamPreview && d.bool(forKey: SimulatorPaneModel.previewKey) == false)
        m.isPreviewEnabled = true
        m.undock(); #expect(!m.shouldStreamPreview, "no frame capture while undocked")
        m.hide(); #expect(!m.shouldStreamPreview)
        m.dock(); #expect(m.shouldStreamPreview)
        // A new model (relaunch) restores the saved choice.
        m.isPreviewEnabled = false
        let relaunched = SimulatorPaneModel(manager: nil, runnerTargetUDID: a, defaults: d, openRealSimulator: {})
        #expect(!relaunched.isPreviewEnabled)
        let k = await c.calls()
        #expect(k.boots.isEmpty && k.shutdowns.isEmpty)
    }

    @Test func testPreviewSettingHonoursLaunchArgumentStyleStringValues() {
        // `-embeddedSimulatorPreview NO` reaches UserDefaults as the string "NO", not a Bool.
        let d = UserDefaults(suiteName: "sim-tests-\(UUID().uuidString)")!
        d.set("NO", forKey: SimulatorPaneModel.previewKey)
        #expect(SimulatorPaneModel(manager: nil, runnerTargetUDID: a, defaults: d, openRealSimulator: {}).isPreviewEnabled == false)
        d.set("YES", forKey: SimulatorPaneModel.previewKey)
        #expect(SimulatorPaneModel(manager: nil, runnerTargetUDID: a, defaults: d, openRealSimulator: {}).isPreviewEnabled == true)
        d.removeObject(forKey: SimulatorPaneModel.previewKey)
        #expect(SimulatorPaneModel(manager: nil, runnerTargetUDID: a, defaults: d, openRealSimulator: {}).isPreviewEnabled == true, "unset means on")
    }

    @Test func testDisablingPreviewFreesTheFrameAndNeverTouchesTheDevice() async {
        let (m, c, _, _) = make()
        await m.refresh(); await m.activateSelected()
        m.isPreviewEnabled = false
        m.isPreviewEnabled = true; m.isPreviewEnabled = false
        #expect(m.mirror.frame == nil && !m.mirror.isStreaming)
        let k = await c.calls()
        #expect(k.boots == [a] && k.shutdowns.isEmpty, "lifecycle independent from the preview")
        #expect(m.activeUDID == a && m.deviceState == .booted)
    }

    @Test func testLifecycleActionsGoThroughTheManager() async {
        let (m, c, _, _) = make()
        await m.refresh(); await m.activateSelected()
        await m.launchTargetApp()
        await m.installApp(at: "/tmp/Some.app")
        let k = await c.calls()
        #expect(k.launches.first == m.targetBundleID)
        #expect(k.installs == 1)
        await m.shutdownActive()
        #expect(m.deviceState == .shutdown && m.activeUDID == nil)
        await m.launchTargetApp()
        #expect(m.lastError != nil, "launching without a session reports why")
    }

    @Test func testSelectingAnotherDeviceWarnsThatTestsStillTargetTheRunner() async {
        let (m, _, _, _) = make()
        await m.refresh()
        #expect(!m.selectionDiffersFromRunnerTarget)
        m.select(udid: FakeSimulatorClient.phoneB.udid)
        #expect(m.selectionDiffersFromRunnerTarget && m.deviceTitle == "iPhone 17 Pro")
    }

    @Test func testModelWithoutManagerIsInertButUsable() async {
        let m = SimulatorPaneModel(manager: nil, runnerTargetUDID: a, defaults: UserDefaults(suiteName: "sim-tests-\(UUID().uuidString)")!, openRealSimulator: {})
        await m.refresh(); await m.activateSelected()
        #expect(!m.canManage && m.bootState == .unknown && m.lastError == nil)
        m.undock(); m.dock()
    }



}
