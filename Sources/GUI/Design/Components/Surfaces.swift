import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// Rounded surface for grouped content. `tone` tints it (for example red for a failed step).
struct Card<Content: View>: View {
    var tone: StatusTone?
    var isSelected = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsSurface(tint: tone.map(\.tint), selected: isSelected)
    }
}

/// Small uppercase heading above a block of content.
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a section shows when there is nothing to list (or something went wrong), with an optional way forward.
struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: symbol).font(DS.Typography.heroSymbol).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if let action { Button(action.title, action: action.run).padding(.top, DS.Space.xs) }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A message that sits in the page: an error, a warning, a note. It wraps, it can be dismissed, and its tone is spoken as well as coloured.
struct InlineBanner: View {
    let tone: StatusTone
    let text: String
    var dismiss: (() -> Void)?

    private var symbol: String {
        switch tone {
        case .failure: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .active, .neutral: return "info.circle.fill"
        }
    }

    private var spokenPrefix: String {
        switch tone {
        case .failure: return "Error: "
        case .warning: return "Warning: "
        default: return ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: symbol).foregroundStyle(tone.tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: DS.Space.s)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss").accessibilityLabel("Dismiss message")
            }
        }
        .padding(DS.Space.m)
        .dsSurface(tint: tone.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenPrefix + text)
    }
}
