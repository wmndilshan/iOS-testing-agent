import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// The simulator's live picture at phone aspect ratio, with a LIVE / idle indicator. View only: nothing here can touch the device.
struct LivePreview: View {
    @EnvironmentObject var simulator: SimulatorPaneModel

    var body: some View {
        VStack(spacing: DS.Space.m) {
            HStack {
                Text(simulator.deviceTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                LiveIndicator(mirror: simulator.mirror)
            }
            LiveFrame(mirror: simulator.mirror, udid: simulator.selectedUDID)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct LiveIndicator: View {
    @ObservedObject var mirror: SimulatorMirror

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = mirror.error == nil && mirror.frame != nil && (mirror.lastFrameAt.map { context.date.timeIntervalSince($0) < 4 } ?? false)
            StatusBadge(text: live ? "LIVE" : "Idle", tone: live ? .success : .neutral, symbol: live ? "dot.radiowaves.left.and.right" : "pause.circle")
        }
    }
}

/// The frame itself, rounded like a phone. Attaches to the shared capture while it is on screen.
struct LiveFrame: View {
    @ObservedObject var mirror: SimulatorMirror
    let udid: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(Color.black)
            if let image = mirror.frame {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 24)).padding(4)
                    .accessibilityLabel("Live simulator screen")
            } else if let error = mirror.error {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "iphone.slash").font(.title2)
                    Text(error).font(.caption).multilineTextAlignment(.center).lineLimit(5)
                }
                .foregroundStyle(.white.opacity(0.7)).padding(DS.Space.m)
            } else {
                VStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to the simulator").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .aspectRatio(DS.phoneAspect, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .onAppear { mirror.attach(udid: udid) }
        .onDisappear { mirror.detach() }
        .onChange(of: udid) { newUDID in mirror.detach(); mirror.attach(udid: newUDID) }
    }
}
