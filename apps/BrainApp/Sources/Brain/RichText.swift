import AppKit
import BrainCore
import SwiftUI

/// Answer text as one selectable NSTextView: unlike SwiftUI Text it has real paragraph styles, so list items wrap under their
/// text (hanging indent), paragraphs get room between them and markers can be colored symbols, while a selection still runs
/// across headings, paragraphs and lists.
struct RichText: NSViewRepresentable {
    let blocks: [MDBlock]
    /// The first block of the answer: no space above it.
    var leading = true

    func makeNSView(context: Context) -> AnswerTextView { AnswerTextView.make() }

    func updateNSView(_ v: AnswerTextView, context: Context) {
        let s = RichText.attributed(blocks, leading: leading)
        if v.textStorage?.isEqual(to: s) != true { v.textStorage?.setAttributedString(s) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: AnswerTextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 640
        return CGSize(width: w, height: v.height(for: w))
    }

    // MARK: building the text

    static let body: CGFloat = 14.5
    static let accent = NSColor.systemPurple

    static func attributed(_ blocks: [MDBlock], leading: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, b) in blocks.enumerated() {
            let first = leading && i == 0
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            switch b {
            case .heading(let level, let t):
                out.append(heading(t, level: level, first: first))
            case .paragraph(let t):
                // a paragraph that is only bold ("**Kalendár (11)**") is the model's way of writing a section label
                // (the answer's very first one is its title, e.g. "**Ranný prehľad, piatok 6. 11.**")
                if let label = boldOnly(t) { out.append(heading(label, level: first ? 2 : 4, first: first)) }
                else { out.append(paragraph(t, first: first)) }
            case .list(let items):
                for (j, it) in items.enumerated() {
                    if j > 0 { out.append(NSAttributedString(string: "\n")) }
                    out.append(item(it, first: first && j == 0, last: j == items.count - 1))
                }
            case .quote(let t):
                out.append(paragraph(t, first: first))
            case .table, .code, .rule:
                break   // cards, outside the text
            }
        }
        return out
    }

    static func style(before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0, head: CGFloat = 0, tab: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3.5
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.firstLineHeadIndent = indent
        p.headIndent = head
        p.tabStops = tab.map { [NSTextTab(textAlignment: .left, location: $0)] } ?? []
        p.defaultTabInterval = 0
        return p
    }

    static func heading(_ t: String, level: Int, first: Bool) -> NSAttributedString {
        let (size, weight, color, before): (CGFloat, NSFont.Weight, NSColor, CGFloat) = switch level {
        case 1: (19, .semibold, .labelColor, 18)
        case 2: (16.5, .semibold, .labelColor, 16)
        case 3: (14.5, .semibold, .labelColor, 12)
        default: (13, .semibold, .secondaryLabelColor, 12)   // section labels: quieter, like a list header
        }
        let s = inline(t, size: size, weight: weight, color: color)
        s.addAttribute(.paragraphStyle, value: style(before: first ? 0 : before, after: level <= 2 ? 6 : 4), range: NSRange(location: 0, length: s.length))
        if level >= 4 { s.addAttribute(.kern, value: 0.2, range: NSRange(location: 0, length: s.length)) }
        return s
    }

    static func paragraph(_ t: String, first: Bool) -> NSAttributedString {
        let s = inline(t, size: body)
        s.addAttribute(.paragraphStyle, value: style(before: first ? 0 : 6, after: 6), range: NSRange(location: 0, length: s.length))
        return s
    }

    static func item(_ it: MDListItem, first: Bool, last: Bool) -> NSAttributedString {
        let indent = CGFloat(it.depth) * 20, gutter: CGFloat = 20
        let s = NSMutableAttributedString()
        switch it.marker {
        case .bullet:
            s.append(NSAttributedString(string: it.depth == 0 ? "●" : "○", attributes: [
                .font: NSFont.systemFont(ofSize: 7), .foregroundColor: it.depth == 0 ? accent.withAlphaComponent(0.8) : NSColor.tertiaryLabelColor,
                .baselineOffset: 2.5]))
        case .number(let n):
            s.append(NSAttributedString(string: n + ".", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: body - 1, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
        case .task(let done):
            s.append(symbol(done ? "checkmark.circle.fill" : "circle", color: done ? accent : .secondaryLabelColor))
        }
        s.append(NSAttributedString(string: "\t"))
        let text = inline(it.text, size: body)
        if case .task(true) = it.marker {
            text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor],
                               range: NSRange(location: 0, length: text.length))
        }
        s.append(text)
        s.addAttribute(.paragraphStyle, value: style(before: first ? 0 : 0, after: last ? 6 : 5, indent: indent + 2, head: indent + gutter, tab: indent + gutter),
                       range: NSRange(location: 0, length: s.length))
        return s
    }

    static func symbol(_ name: String, color: NSColor, size: CGFloat = body - 1) -> NSAttributedString {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))) else { return NSAttributedString(string: "•") }
        let a = NSTextAttachment()
        a.image = img
        // centred on the text's x-height
        a.bounds = CGRect(x: 0, y: (body - img.size.height) / 2 - 3, width: img.size.width, height: img.size.height)
        return NSAttributedString(attachment: a)
    }

    /// "**Kalendár (11)**" → "Kalendár (11)"; nil when the paragraph has anything besides one bold run.
    static func boldOnly(_ t: String) -> String? {
        let s = t.trimmingCharacters(in: .whitespaces)
        guard s.count > 4, s.count < 80, !s.contains("\n") else { return nil }
        for m in ["**", "__"] where s.hasPrefix(m) && s.hasSuffix(m) {
            let inner = String(s.dropFirst(2).dropLast(2))
            if !inner.contains(m) { return inner.hasSuffix(":") ? String(inner.dropLast()) : inner }
        }
        return nil
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) → attributes in the system font.
    static func inline(_ t: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSMutableAttributedString {
        let a = (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
        let out = NSMutableAttributedString()
        for run in a.runs {
            let text = String(a[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) {
                if text.count <= 20, !text.contains(" "), !text.contains("/") {
                    // a short code span is a tag (`Kudosky`, `10T`): quiet colored label rather than code
                    font = .systemFont(ofSize: size - 2, weight: .semibold)
                    attrs[.foregroundColor] = accent
                    attrs[.backgroundColor] = accent.withAlphaComponent(0.10)
                    attrs[.kern] = 0.3
                } else {
                    font = .monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
                    attrs[.foregroundColor] = NSColor.secondaryLabelColor
                    attrs[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                }
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let l = run.link { attrs[.link] = l }
            attrs[.font] = font
            out.append(withSymbols(text, attrs: attrs, size: size))
        }
        return out
    }

    /// Emoji the answers use, as SF Symbols in their color: they match the rest of the series (Meetingy, Fitness) and don't
    /// shout. Anything not listed stays as it is.
    static let emojiSymbols: [Character: (String, NSColor)] = [
        "🔴": ("circle.fill", .systemRed), "🟠": ("circle.fill", .systemOrange), "🟡": ("circle.fill", .systemYellow),
        "🟢": ("circle.fill", .systemGreen), "🔵": ("circle.fill", .systemBlue), "🟣": ("circle.fill", .systemPurple), "⚪": ("circle", .secondaryLabelColor),
        "🎉": ("party.popper.fill", .systemPink), "🥳": ("party.popper.fill", .systemPink), "🎂": ("birthday.cake.fill", .systemPink), "🎁": ("gift.fill", .systemPink),
        "⚠️": ("exclamationmark.triangle.fill", .systemOrange), "⚠": ("exclamationmark.triangle.fill", .systemOrange), "❗": ("exclamationmark.circle.fill", .systemRed),
        "✅": ("checkmark.circle.fill", .systemGreen), "✔️": ("checkmark", .systemGreen), "☑️": ("checkmark.square.fill", .systemGreen),
        "❌": ("xmark.circle.fill", .systemRed), "⛔": ("minus.circle.fill", .systemRed), "🚫": ("nosign", .systemRed),
        "📅": ("calendar", .systemRed), "🗓️": ("calendar", .systemRed), "⏰": ("alarm.fill", .systemOrange), "⏳": ("hourglass", .systemOrange), "🕐": ("clock.fill", .secondaryLabelColor),
        "📧": ("envelope.fill", .systemBlue), "✉️": ("envelope.fill", .systemBlue), "📨": ("envelope.open.fill", .systemBlue), "💬": ("bubble.left.fill", .systemGreen),
        "📞": ("phone.fill", .systemGreen), "📱": ("iphone", .secondaryLabelColor),
        "💰": ("dollarsign.circle.fill", .systemGreen), "💵": ("banknote.fill", .systemGreen), "💸": ("banknote.fill", .systemRed),
        "📈": ("chart.line.uptrend.xyaxis", .systemGreen), "📉": ("chart.line.downtrend.xyaxis", .systemRed), "📊": ("chart.bar.fill", .systemBlue),
        "🔁": ("repeat", .systemPurple), "🔄": ("arrow.triangle.2.circlepath", .systemBlue), "🔔": ("bell.fill", .systemOrange), "📌": ("pin.fill", .systemRed),
        "📝": ("square.and.pencil", .systemBlue), "📄": ("doc.text.fill", .secondaryLabelColor), "📁": ("folder.fill", .systemBlue), "📎": ("paperclip", .secondaryLabelColor),
        "🔗": ("link", .systemBlue), "🔍": ("magnifyingglass", .secondaryLabelColor), "💡": ("lightbulb.fill", .systemYellow), "⭐": ("star.fill", .systemYellow),
        "🔥": ("flame.fill", .systemOrange), "🚀": ("paperplane.fill", .systemBlue), "🏋️": ("figure.strengthtraining.traditional", .systemOrange),
        "🏃": ("figure.run", .systemPink), "🚴": ("figure.outdoor.cycle", .systemGreen), "🍽️": ("fork.knife", .systemOrange), "🛒": ("cart.fill", .systemGreen),
        "👉": ("arrow.right", .secondaryLabelColor), "➡️": ("arrow.right", .secondaryLabelColor), "👍": ("hand.thumbsup.fill", .systemBlue), "🤝": ("hands.clap.fill", .systemOrange),
    ]

    static func withSymbols(_ text: String, attrs: [NSAttributedString.Key: Any], size: CGFloat) -> NSAttributedString {
        guard text.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) else {
            return NSAttributedString(string: text, attributes: attrs)
        }
        let out = NSMutableAttributedString()
        var plain = ""
        for ch in text {
            let key = emojiSymbols[ch] != nil ? ch : Character(String(ch.unicodeScalars.filter { $0.value != 0xFE0F }))
            if let (name, color) = emojiSymbols[key] {
                if !plain.isEmpty { out.append(NSAttributedString(string: plain, attributes: attrs)); plain = "" }
                let sym = symbol(name, color: color, size: name == "circle.fill" ? size - 6 : size - 1)
                let m = NSMutableAttributedString(attributedString: sym)
                m.addAttributes(attrs.filter { $0.key == .link }, range: NSRange(location: 0, length: m.length))
                out.append(m)
            } else {
                plain.append(ch)
            }
        }
        if !plain.isEmpty { out.append(NSAttributedString(string: plain, attributes: attrs)) }
        return out
    }
}

/// A read-only, transparent, non-scrolling text view that tells SwiftUI how tall it is for a width.
final class AnswerTextView: NSTextView {
    static func make() -> AnswerTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let v = AnswerTextView(frame: .zero, textContainer: container)
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.linkTextAttributes = [.foregroundColor: RichText.accent, .cursor: NSCursor.pointingHand]
        v.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    func height(for width: CGFloat) -> CGFloat {
        guard let c = textContainer, let l = layoutManager else { return 0 }
        c.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        l.ensureLayout(for: c)
        return ceil(l.usedRect(for: c).height) + 2
    }

    /// file:// links open the file; other links open as usual.
    override func clicked(onLink link: Any, at charIndex: Int) {
        if let u = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
    }
}
