import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

struct VerdictCard: View {
    let message: AgentChatMessage
    let caseKey: String
    let openHistory: () -> Void

    private var tone: StatusTone {
        switch message.text { case "PASS": .success; case "FAIL": .failure; case "INCOMPLETE": .warning; default: .neutral }
    }

    private var symbol: String {
        switch message.text { case "PASS": "checkmark.seal.fill"; case "FAIL": "xmark.seal.fill"; case "INCOMPLETE": "exclamationmark.circle.fill"; default: "doc.text" }
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tone.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text == "NONE" ? "Case written, not run" : message.text).font(.headline).foregroundStyle(tone.tint)
                if !caseKey.isEmpty { Text("Case \(caseKey)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if !caseKey.isEmpty { Button("Open in History", action: openHistory).controlSize(.small) }
        }
        .padding(DS.Space.m)
        .dsSurface(radius: DS.Radius.l, tint: tone.tint, borderOpacity: 0.4)
    }
}
