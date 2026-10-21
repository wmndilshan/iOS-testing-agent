import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

struct UserBubble: View {
    let message: AgentChatMessage

    var body: some View {
        HStack {
            Spacer(minLength: 96)
            Text(message.text).textSelection(.enabled).lineSpacing(3)
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                .background(DS.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: DS.Radius.l))
        }
    }
}

/// What the orchestrator says to the person: avatar, name, rendered markdown. No bubble: long answers read like a document.
struct AssistantMessageView: View, Equatable {
    let message: AgentChatMessage
    @State private var hovering = false

    nonisolated static func == (a: AssistantMessageView, b: AssistantMessageView) -> Bool { a.message == b.message }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            AgentAvatar(name: message.agent)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text(message.agent).font(.caption.weight(.semibold)).foregroundStyle(AgentStyle.color(message.agent))
                    Spacer()
                    if hovering && !message.isOpen { CopyButton(text: message.text) }
                }
                MarkdownView(text: message.text, selectable: !message.isOpen).equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { Button("Copy message") { Clipboard.copy(message.text) } }
    }
}
