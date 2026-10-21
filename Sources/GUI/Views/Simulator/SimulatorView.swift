import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// The simulator: device state, the buttons that boot, shut down and launch, and the live picture. No way to touch the app under test.
struct SimulatorView: View {
    @EnvironmentObject var simulator: SimulatorPaneModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: DS.Space.m) {
                if let error = simulator.lastError {
                    InlineBanner(tone: .failure, text: error, dismiss: { simulator.dismissError() })
                }
                if simulator.isPreviewEnabled {
                    LiveFrame(mirror: simulator.mirror, udid: simulator.selectedUDID).frame(maxHeight: .infinity)
                } else {
                    EmptyState(symbol: "eye.slash", title: "Live view is off", detail: "Turn it on to see the device here.",
                               action: (title: "Turn on live view", run: { simulator.isPreviewEnabled = true }))
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(simulator.deviceTitle).font(.title3.weight(.semibold))
                HStack(spacing: DS.Space.s) {
                    StatusPill(text: simulator.bootState.rawValue, tone: simulator.bootState.tone)
                    if !simulator.osTitle.isEmpty { Text(simulator.osTitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if simulator.isBusy {
                ProgressView().controlSize(.small)
                Text(simulator.busyLabel ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            LiveIndicator(mirror: simulator.mirror)
            Toggle("Live view", isOn: $simulator.isPreviewEnabled).toggleStyle(.switch).controlSize(.small)
            if simulator.deviceState == .booted {
                Button { Task { await simulator.shutdownActive() } } label: { Label("Shut Down", systemImage: "power") }
                    .disabled(simulator.isBusy)
            } else {
                Button { Task { await simulator.activateSelected() } } label: { Label("Boot", systemImage: "power.circle") }
                    .disabled(simulator.isBusy || !simulator.canManage)
            }
            Button { Task { await simulator.launchTargetApp() } } label: { Label("Launch App", systemImage: "play.rectangle") }
                .disabled(simulator.deviceState != .booted || simulator.isBusy).help("Launch \(simulator.targetBundleID)")
        }
        .controlSize(.large)
        .padding(DS.Space.l)
    }
}
