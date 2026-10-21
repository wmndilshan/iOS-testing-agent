import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// An agent's reasoning: a short live window while it streams, folded to one line when it finishes.
struct ThinkingBlock: View, Equatable {
    let message: AgentChatMessage
    @State private var expanded = false

    nonisolated static func == (a: ThinkingBlock, b: ThinkingBlock) -> Bool { a.message == b.message }

    private var label: String {
        if message.isOpen { return "Thinking…" }
        if let end = message.endedAt { return "Thought for \(max(1, Int(end.timeIntervalSince(message.date).rounded())))s" }
        return "Thought"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: DS.Space.xs) {
                    if message.isOpen { InlineSpinner() } else { Image(systemName: "brain").imageScale(.small) }
                    Text(label)
                    Image(systemName: expanded || message.isOpen ? "chevron.down" : "chevron.right").imageScale(.small)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).accessibilityLabel("Reasoning of \(message.agent)")
            if expanded || message.isOpen {
                // The tail of a long reasoning is what is happening now; a fixed height keeps the window from growing with it.
                ScrollView {
                    Text(message.isOpen ? String(message.text.suffix(1200)) : message.text)
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: message.isOpen ? 96 : 220)
                .padding(.leading, DS.Space.m)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool call as a compact line: what it was, its main argument, how long it took; click for the full call and result.
struct ToolRow: View, Equatable {
    let message: AgentChatMessage
    @State private var expanded = false

    nonisolated static func == (a: ToolRow, b: ToolRow) -> Bool { a.message == b.message }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: DS.Space.s) {
                    if message.result == nil { ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 14, height: 14) }
                    else { Image(systemName: message.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(message.succeeded ? StatusTone.success.tint : StatusTone.failure.tint).imageScale(.small).frame(width: 14) }
                    Image(systemName: AgentStyle.toolSymbol(message.toolName)).foregroundStyle(.secondary).imageScale(.small).frame(width: 14)
                    Text(message.toolName).font(DS.Typography.monoCaption.weight(.semibold))
                    if message.toolName == "run_case" && message.result == nil {
                        Text("waiting for your approval, then the simulator run").font(.caption.weight(.medium)).foregroundStyle(StatusTone.warning.tint).lineLimit(1)
                    } else {
                        Text(AgentStyle.argumentSummary(message.text)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: DS.Space.s)
                    if let ms = message.milliseconds { Text(ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Tool \(message.toolName)")
            if expanded {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(message.text).font(DS.Typography.monoCaption).foregroundStyle(.secondary)
                    if let result = message.result {
                        Divider()
                        Text(result).font(DS.Typography.monoCaption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                .frame(maxHeight: 220, alignment: .top)
                .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.s)
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.s))
    }
}

/// One specialist's work as a card: who, what it was asked, live progress, and its report. Open while it works, folded when it is done.
struct AgentSectionCard: View, Equatable {
    let section: AgentSection
    @State private var expanded: Bool?

    nonisolated static func == (a: AgentSectionCard, b: AgentSectionCard) -> Bool { a.section == b.section }

    private var isExpanded: Bool { expanded ?? section.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded = !isExpanded } } label: {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    AgentAvatar(name: section.agent)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Space.s) {
                            Text(section.agent).font(.callout.weight(.semibold)).foregroundStyle(AgentStyle.color(section.agent))
                            if section.isActive { Text("working").font(.caption).foregroundStyle(.secondary) }
                            else if let seconds = section.seconds { Text("\(seconds)s").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            if section.toolCount > 0 { Text("· " + Format.count(section.toolCount, "tool call")).font(.caption).foregroundStyle(.secondary) }
                            if section.failedToolCount > 0 { Text("· \(section.failedToolCount) failed").font(.caption).foregroundStyle(StatusTone.failure.tint) }
                        }
                        Text(section.task).font(.caption).foregroundStyle(.secondary).lineLimit(isExpanded ? 4 : 1).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: DS.Space.s)
                    if section.isActive { ProgressView().controlSize(.small) }
                    else { Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusTone.success.tint) }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                }
                .padding(DS.Space.m).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("\(section.agent) work")

            if isExpanded && !section.items.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(section.items) { item in
                        switch item.kind {
                        case .thinking: ThinkingBlock(message: item).equatable()
                        case .tool: ToolRow(message: item).equatable()
                        default: MarkdownView(text: item.text, selectable: !item.isOpen).equatable()
                        }
                    }
                }
                .padding(DS.Space.m)
            }
        }
        .dsSurface(radius: DS.Radius.l, tint: section.isActive ? AgentStyle.color(section.agent) : nil, borderOpacity: 0.55)
    }
}
