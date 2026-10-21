import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// Chooses how the team of agents is set up: a preset, or each specialist on or off with its model tier and limits.
struct FlowEditor: View {
    @EnvironmentObject var chat: AgentChatState

    private static let customName = "Custom"

    private var selectedPreset: String {
        AgentFlow.presets.first { $0 == chat.flow }?.name ?? Self.customName
    }

    var body: some View {
        Picker("Flow", selection: Binding(get: { selectedPreset }, set: { choose($0) })) {
            ForEach(AgentFlow.presets) { Text($0.name).tag($0.name) }
            if selectedPreset == Self.customName { Text(Self.customName).tag(Self.customName) }
        }
        .disabled(chat.isBusy)
        ForEach(AgentFlow.Role.allCases) { role in member(role) }
        Stepper("Orchestrator turns: \(chat.flow.orchestratorMaxTurns)", value: edit(\.orchestratorMaxTurns), in: 2...30)
            .disabled(chat.isBusy)
        Text(chat.isBusy ? "The flow can be changed when the agents are idle." : "A change applies from the next message. The orchestrator always takes part; the prompts and tools of each specialist are fixed.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func member(_ role: AgentFlow.Role) -> some View {
        let enabled = memberBinding(role, \.enabled)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Toggle(isOn: enabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.rawValue)
                    Text(role.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            // The last specialist cannot be turned off: a team of only an orchestrator has nobody to delegate to.
            .disabled(chat.isBusy || (chat.flow[role].enabled && chat.flow.enabledRoles.count == 1))
            if chat.flow[role].enabled {
                HStack(spacing: DS.Space.m) {
                    Picker("Model", selection: memberBinding(role, \.tier)) {
                        ForEach(AgentFlow.Tier.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130).help("Strong models reason better; fast ones cost less")
                    Stepper("Turns \(chat.flow[role].maxTurns)", value: memberBinding(role, \.maxTurns), in: 1...20)
                    Stepper("Tool calls \(chat.flow[role].maxToolCalls)", value: memberBinding(role, \.maxToolCalls), in: 1...60, step: 2)
                }
                .font(.caption).disabled(chat.isBusy)
                .padding(.leading, 20)
            }
        }
    }

    private func choose(_ name: String) {
        if let preset = AgentFlow.presets.first(where: { $0.name == name }) { chat.setFlow(preset) }
    }

    private func edit<V>(_ keyPath: WritableKeyPath<AgentFlow, V>) -> Binding<V> {
        Binding(get: { chat.flow[keyPath: keyPath] }, set: { value in
            var flow = chat.flow
            flow[keyPath: keyPath] = value
            commit(flow)
        })
    }

    private func memberBinding<V>(_ role: AgentFlow.Role, _ keyPath: WritableKeyPath<AgentFlow.Member, V>) -> Binding<V> {
        Binding(get: { chat.flow[role][keyPath: keyPath] }, set: { value in
            var flow = chat.flow
            flow[role][keyPath: keyPath] = value
            commit(flow)
        })
    }

    /// An edited flow is named "Custom" unless it is exactly a preset again.
    private func commit(_ edited: AgentFlow) {
        var flow = edited
        flow.name = Self.customName
        if let preset = AgentFlow.presets.first(where: { var copy = flow; copy.name = $0.name; return copy == $0 }) { flow = preset }
        chat.setFlow(flow)
    }
}

/// The toolbar's quick switch between flow presets.
struct FlowMenu: View {
    @EnvironmentObject var chat: AgentChatState

    var body: some View {
        Menu {
            ForEach(AgentFlow.presets) { preset in
                Button { chat.setFlow(preset) } label: {
                    if preset == chat.flow { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                }
            }
            Divider()
            Button("Customize…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        } label: {
            Label(chat.flow.name, systemImage: "point.3.connected.trianglepath.dotted")
        }
        .labelStyle(.titleAndIcon)
        .disabled(chat.isBusy)
        .help("How the team of agents is set up: \(chat.flow.teamNames.joined(separator: ", "))")
        .accessibilityLabel("Agent flow")
    }
}
