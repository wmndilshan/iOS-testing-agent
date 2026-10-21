import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// The top of the Operate section: what the task is, what is happening right now, how far along it is, and the controls.
struct OperateHeader: View {
    @ObservedObject var operate: OperateState

    private var doneCount: Int { operate.goals.filter { $0.state == .done }.count }
    private var progress: Double { operate.goals.isEmpty ? 0 : Double(doneCount) / Double(operate.goals.count) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(operate.task.isEmpty ? "Operate" : operate.task).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.s) {
                        Text(activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if operate.phase != .idle, !operate.goals.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text("\(doneCount) of \(operate.goals.count) goals").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if operate.isRunning {
                            Text("·").foregroundStyle(.tertiary)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Format.duration(max(0, context.date.timeIntervalSince(operate.startedAt)))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: DS.Space.m)
                pill
                controls
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            if operate.phase != .idle, !operate.goals.isEmpty {
                ProgressView(value: progress).progressViewStyle(.linear).tint(operate.phase == .finished(done: false) ? StatusTone.failure.tint : DS.accent)
                    .controlSize(.mini).padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.s)
            }
        }
    }

    private var activity: String {
        if operate.blockedReason != nil { return "Waiting for you" }
        switch operate.phase {
        case .idle: return operate.deviceAvailable ? "A team of agents that operates the simulator" : "idb was not found, so the simulator cannot be operated"
        case .paused: return "Paused"
        case .finished(let done): return done ? "Finished" : "Stopped before every goal passed"
        case .running:
            if operate.activeNode.isEmpty { return operate.modelName.isEmpty ? "Starting" : "Starting · \(operate.modelName)" }
            return OperateState.nodeTitle(operate.activeNode) + (operate.activeAgent.isEmpty ? "" : " · \(operate.activeAgent)")
        }
    }

    @ViewBuilder private var pill: some View {
        switch operate.phase {
        case .idle: EmptyView()
        case .running: StatusPill(text: operate.isWaitingForPerson ? "Waiting for you" : "Working", tone: operate.isWaitingForPerson ? .warning : .active)
        case .paused: StatusPill(text: "Paused", tone: .warning)
        case .finished(let done): StatusPill(text: done ? "Done" : "Not finished", tone: done ? .success : .failure)
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: DS.Space.s) {
            if operate.phase == .running { Button { operate.pause() } label: { Label("Pause", systemImage: "pause.fill") }.help("Hold the agents so you can take over") }
            if operate.isPaused { Button { operate.resume() } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.borderedProminent) }
            if operate.isRunning { Button(role: .destructive) { operate.stop() } label: { Label("Stop", systemImage: "stop.fill") } }
            else if operate.phase != .idle { Button { operate.newSession() } label: { Label("New task", systemImage: "plus") } }
        }
    }
}
