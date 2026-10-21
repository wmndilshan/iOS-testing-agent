import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// A question the agents are waiting on (to run a case on the simulator). It sits under the header, outside the scrolling conversation, so it
/// can never be scrolled away or hidden; it shows what is about to run.
struct ApprovalBanner: View {
    let prompt: AgentPrompt
    let info: AgentCaseInfo?
    let answer: (String) -> Void
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "hand.raised.fill").foregroundStyle(StatusTone.warning.tint)
                Text(prompt.title).font(.headline)
                Spacer()
                Text("The agents are waiting for you").font(.caption).foregroundStyle(StatusTone.warning.tint)
            }
            Text(prompt.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let info {
                Button { withAnimation(.easeInOut(duration: 0.15)) { showSteps.toggle() } } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: showSteps ? "chevron.down" : "chevron.right").imageScale(.small)
                        Text("\(info.title) · \(info.steps.count) steps").lineLimit(1)
                    }
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain).foregroundStyle(DS.accent).accessibilityLabel("Show the steps that will run")
                if showSteps {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            ForEach(info.steps, id: \.number) { step in
                                Text("\(step.number). \(step.action)").font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
            HStack {
                Spacer()
                Button("Deny") { answer("deny") }.keyboardShortcut(.cancelAction).accessibilityLabel("Deny the run")
                Button("Approve and run") { answer("approve") }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityLabel("Approve the run")
            }
        }
        .padding(DS.Space.m)
        .dsSurface(radius: DS.Radius.l, tint: StatusTone.warning.tint, borderOpacity: 0.55)
    }
}

/// A device command the agents want to run, in words. Read-only commands never ask; reversible ones ask once and can be allowed for the
/// chat; destructive ones ask every time.
struct DeviceApprovalBanner: View {
    let approval: DeviceApproval
    let answer: (DeviceAnswer) -> Void

    private var destructive: Bool { approval.risk == .destructive }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: destructive ? "exclamationmark.triangle.fill" : "iphone.gen3.radiowaves.left.and.right")
                    .foregroundStyle(destructive ? StatusTone.failure.tint : StatusTone.warning.tint)
                Text(destructive ? "Allow a destructive device command?" : "Allow this device command?").font(.headline)
                Spacer()
                Text("The agents are waiting for you").font(.caption).foregroundStyle(StatusTone.warning.tint)
            }
            Text(approval.phrase).font(.callout.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(destructive ? "This cannot be undone and is asked every time." : "It changes the device, but is easy to undo or repeat.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Deny") { answer(.deny) }.keyboardShortcut(.cancelAction).accessibilityLabel("Deny this device command")
                if approval.offersChatGrant {
                    Button("Allow for this chat") { answer(.allowForChat) }.help("Reversible device commands in this chat run without asking again")
                        .accessibilityLabel("Allow device commands for this chat")
                }
                Button("Allow once") { answer(.approveOnce) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityLabel("Allow this device command once")
            }
        }
        .padding(DS.Space.m)
        .dsSurface(radius: DS.Radius.l, tint: destructive ? StatusTone.failure.tint : StatusTone.warning.tint, borderOpacity: 0.55)
    }
}
