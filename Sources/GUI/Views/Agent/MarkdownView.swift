import SwiftUI
import AppKit
import AgentCore
import AgentPresentation
import AgentComposition

/// Parsed documents by text, so a finished message is parsed once however often the window redraws.
@MainActor private enum MarkdownCache {
    private final class Box { let blocks: [MarkdownBlock]; init(_ blocks: [MarkdownBlock]) { self.blocks = blocks } }
    private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 300; return c }()

    static func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = MarkdownParser.parse(text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}

private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

/// Renders model text as readable rich text: headings, lists, tables, quotes, code blocks with a copy button, and inline styling.
struct MarkdownView: View, Equatable {
    let text: String
    var selectable = true

    nonisolated static func == (a: MarkdownView, b: MarkdownView) -> Bool { a.text == b.text && a.selectable == b.selectable }

    var body: some View {
        let blocks = MarkdownCache.blocks(for: text)
        let content = VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in render(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if selectable { content.textSelection(.enabled) } else { content }
    }

    @ViewBuilder private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text)).font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline).padding(.top, level <= 2 ? DS.Space.xs : 0)
        case .paragraph(let text):
            Text(inline(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(inline(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .task(let indent, let done, let text):
            TaskRow(done: done, text: text).padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            Text(inline(text)).foregroundStyle(.secondary).padding(.leading, DS.Space.m)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .rule:
            Divider().padding(.vertical, DS.Space.xs)
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        }
    }
}

/// A checklist item. The box can be ticked; that is only a note on screen, it is not saved with the message.
private struct TaskRow: View {
    let done: Bool
    let text: String
    @State private var override: Bool?

    private var isDone: Bool { override ?? done }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Button { withAnimation(.easeInOut(duration: 0.12)) { override = !isDone } } label: {
                Image(systemName: isDone ? "checkmark.square.fill" : "square").foregroundStyle(isDone ? StatusTone.success.tint : .secondary)
            }
            .buttonStyle(.plain).accessibilityLabel(isDone ? "Done" : "Not done").accessibilityAddTraits(.isButton)
            Text(inline(text)).lineSpacing(3).foregroundStyle(isDone ? .secondary : .primary).strikethrough(isDone, color: .secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Highlighted code by language and text, so a finished block is tokenized once however often the window redraws.
@MainActor private enum HighlightCache {
    private final class Box { let text: AttributedString; init(_ text: AttributedString) { self.text = text } }
    private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 200; return c }()

    static func attributed(_ code: String, language: String) -> AttributedString {
        let key = "\(language)\u{0}\(code)" as NSString
        if let hit = cache.object(forKey: key) { return hit.text }
        var result = AttributedString()
        for token in SyntaxHighlighter.tokens(code, language: language) {
            var run = AttributedString(token.text)
            if let color = color(token.kind) { run.foregroundColor = color }
            result.append(run)
        }
        cache.setObject(Box(result), forKey: key)
        return result
    }

    private static func color(_ kind: CodeTokenKind) -> Color? {
        switch kind {
        case .plain: nil
        case .keyword: Color(nsColor: .systemPink)
        case .string: Color(nsColor: .systemOrange)
        case .comment: Color(nsColor: .systemGreen).opacity(0.75)
        case .number: Color(nsColor: .systemBlue)
        case .type: Color(nsColor: .systemTeal)
        case .key: Color(nsColor: .systemBlue)
        case .attribute: Color(nsColor: .systemPurple)
        }
    }
}

private struct CodeBlock: View {
    let language: String
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(Format.count(text.split(separator: "\n", omittingEmptySubsequences: false).count, "line")).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                CopyButton(text: text)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
            .background(Color.primary.opacity(0.06))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(HighlightCache.attributed(text, language: language)).font(DS.Typography.monoCallout).padding(DS.Space.m).fixedSize(horizontal: true, vertical: true)
            }
        }
        .dsSurface()
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.xs) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, cell in Text(inline(cell)).font(.callout.weight(.semibold)) } }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(inline(cell)).font(.callout) } }
                }
            }
            .padding(DS.Space.m)
        }
        .dsSurface()
    }
}
