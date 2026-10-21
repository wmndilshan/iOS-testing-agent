import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// The live simulator next to the task. A ring shows where the agent just tapped; while the agent is paused (or not running) a click on the
/// picture is the person's own tap. Taps go through `OperateState`, which uses the same device port as the agents, so the app stays the
/// only thing that touches the device.
struct LivePanel: View {
    @EnvironmentObject private var simulator: SimulatorPaneModel
    @ObservedObject var operate: OperateState

    private var canTakeOver: Bool { operate.isPaused || !operate.isRunning }

    var body: some View {
        VStack(spacing: DS.Space.s) {
            HStack {
                Text(simulator.deviceTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                LiveIndicator(mirror: simulator.mirror)
            }
            LiveFrame(mirror: simulator.mirror, udid: simulator.selectedUDID)
                .overlay(GeometryReader { proxy in overlay(size: proxy.size) })
            Text(hint).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var hint: String {
        if operate.isPaused { return "Paused. Click, drag, scroll or type on the screen yourself, then Resume." }
        if operate.isRunning { return "Pause to take over by clicking the screen." }
        return "Click to tap, drag to swipe, scroll to scroll, then type on your keyboard."
    }

    @ViewBuilder private func overlay(size: CGSize) -> some View {
        let mapping = ScreenMapping(viewSize: size, pixelSize: simulator.mirror.framePixelSize)
        ZStack {
            if let highlight = operate.highlight {
                HighlightRing(byPerson: highlight.byPerson)
                    .position(mapping.viewPoint(forDevice: highlight.point))
                    .id(highlight.at)
                    .allowsHitTesting(false)
            }
            if canTakeOver {
                LiveInput(
                    onTap: { point in if let device = mapping.devicePoint(forViewPoint: point) { Task { await operate.takeOverTap(at: device) } } },
                    onSwipe: { from, to in
                        if let a = mapping.devicePoint(forViewPoint: from), let b = mapping.devicePoint(forViewPoint: to) { operate.takeOverSwipe(from: a, to: b) }
                    },
                    onScroll: { operate.takeOverScroll($0) },
                    onText: { operate.takeOverText($0) },
                    onKey: { operate.takeOverKey($0) })
                    .accessibilityLabel("Simulator screen: click to tap, drag to swipe, scroll to scroll, type to type")
            }
        }
    }
}

/// A ring that appears where something was tapped, then fades.
struct HighlightRing: View {
    let byPerson: Bool
    @State private var grown = false
    @State private var visible = true

    var body: some View {
        Circle()
            .strokeBorder(byPerson ? DS.Palette.success : DS.accent, lineWidth: 3)
            .background(Circle().fill((byPerson ? DS.Palette.success : DS.accent).opacity(0.25)))
            .frame(width: 44, height: 44)
            .scaleEffect(grown ? 1.0 : 0.4)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { grown = true }
                withAnimation(.easeIn(duration: 0.6).delay(1.2)) { visible = false }
            }
    }
}
