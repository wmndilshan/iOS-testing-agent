import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// "Copy" that says "Copied" for a moment. One button for every place text can be copied.
struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: { Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
    }
}

/// The small spinner used beside a line of text that is still being worked on.
struct InlineSpinner: View {
    var body: some View { ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12) }
}

/// Thin determinate bar, segmented by outcome: passed, failed, remaining.
struct ProgressBar: View {
    let passed: Int
    let failed: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            let unit = total > 0 ? geo.size.width / CGFloat(total) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                HStack(spacing: 0) {
                    Rectangle().fill(StatusTone.success.tint).frame(width: unit * CGFloat(passed))
                    Rectangle().fill(StatusTone.failure.tint).frame(width: unit * CGFloat(failed))
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(passed) passed, \(failed) failed, \(max(total - passed - failed, 0)) remaining")
    }
}

/// The circle that says how a step or action went.
struct StatusIcon: View {
    let status: CaseRunState.Status

    var body: some View {
        Group {
            switch status {
            case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusTone.success.tint)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(StatusTone.failure.tint)
            case .running: ProgressView().controlSize(.small)
            case .unsupported: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(StatusTone.warning.tint)
            case .human: Image(systemName: "person.crop.circle.fill").foregroundStyle(StatusTone.active.tint)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 14)).frame(width: 18, height: 18)
        .accessibilityLabel(status.rawValue)
    }
}
