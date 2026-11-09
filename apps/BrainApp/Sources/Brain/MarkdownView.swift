import BrainCore
import SwiftUI

/// Renders an answer: runs of headings, paragraphs and lists are one RichText (an NSTextView with real paragraph styles), so a
/// selection can span many lines; tables, quotes (drafted texts, with a copy button), code and rules stay cards between them.
struct MarkdownView: View {
    let text: String

    /// Consecutive text blocks together; cards on their own.
    enum Piece { case text([MDBlock]), card(MDBlock) }

    var pieces: [Piece] {
        var out: [Piece] = [], run: [MDBlock] = []
        func flush() { if !run.isEmpty { out.append(.text(run)); run = [] } }
        for b in MarkdownBlocks.parse(text) {
            switch b {
            case .quote, .table, .code, .rule: flush(); out.append(.card(b))
            default: run.append(b)
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { i, p in
                switch p {
                case .text(let blocks): RichText(blocks: blocks, leading: i == 0).frame(maxWidth: .infinity, alignment: .leading)
                case .card(let b): block(b)
                }
            }
        }
        .tint(.brainAccent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func block(_ b: MDBlock) -> some View {
        switch b {
        case .quote(let t):
            QuoteCard(text: t)
        case .table(let header, let rows):
            TableCard(header: header, rows: rows)
        case .code(let t):
            Text(t).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Divider().opacity(0.6).padding(.vertical, 2)
        default:
            EmptyView()
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Quoted text is usually a draft to send: shown as a card with a copy button.
private struct QuoteCard: View {
    let text: String
    @State var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(.brainAccent.opacity(0.6)).frame(width: 3)
            Text(MarkdownView.inline(text)).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(MarkdownView.inline(text).characters), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Kopírovať text")
                .padding(10)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TableCard: View {
    let header: [String]
    let rows: [[String]]

    var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            if !header.isEmpty {
                row(header, bold: true)
                Divider().gridCellUnsizedAxes(.horizontal)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal) }
                row(r, bold: false)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
    }

    func row(_ cells: [String], bold: Bool) -> some View {
        GridRow {
            ForEach(0..<columns, id: \.self) { c in
                Text(MarkdownView.inline(c < cells.count ? cells[c] : ""))
                    .font(.system(size: bold ? 12 : 13, weight: bold ? .semibold : .regular))
                    .foregroundStyle(bold ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
