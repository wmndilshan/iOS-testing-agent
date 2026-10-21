import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// Capsule with a tinted background: an outcome, a state, a count.
struct StatusBadge: View {
    let text: String
    var tone: StatusTone = .neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.tint)
        .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.hair)
        .background(tone.tint.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A quiet neutral capsule for an identifier or a fact: a case key, a bundle id, a count of steps.
struct Chip: View {
    let text: String
    var symbol: String?
    var monospaced = false

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).font(monospaced ? DS.Typography.monoCaption : .caption).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(.secondary).padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.hair)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// Dot plus text, for device and tool state.
struct StatusPill: View {
    let text: String
    var tone: StatusTone = .neutral

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone.tint).frame(width: 8, height: 8)
            Text(text).font(.caption).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
