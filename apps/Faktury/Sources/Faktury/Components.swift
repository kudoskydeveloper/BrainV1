import FakturyCore
import SwiftUI

// The same building blocks as Fitness and Meetings, so the series looks like one family.

enum Fmt {
    static let sk = Locale(identifier: "sk_SK")
    static func day(_ s: String) -> String {
        let d = Day.date(s)
        return Calendar.current.isDate(d, equalTo: .now, toGranularity: .year)
            ? d.formatted(.dateTime.day().month(.abbreviated).locale(sk)) : d.formatted(.dateTime.day().month(.abbreviated).year().locale(sk))
    }
    static func month(_ s: String) -> String {
        let t = Day.date(s.count == 7 ? s + "-01" : s).formatted(.dateTime.month(.wide).year().locale(sk))
        return t.prefix(1).capitalized + t.dropFirst()
    }
    static func shortMonth(_ s: String) -> String { Day.date(s + "-01").formatted(.dateTime.month(.abbreviated).locale(sk)) }
}

struct StatTile: View {
    let title: String, value: String, detail: String?, symbol: String, tint: Color
    init(_ title: String, _ value: String, detail: String? = nil, symbol: String, tint: Color) {
        self.title = title; self.value = value; self.detail = detail; self.symbol = symbol; self.tint = tint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).foregroundStyle(tint)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(14)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

struct StatGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12, alignment: .top)], spacing: 12) { content } }
}

struct Card<Content: View>: View {
    let title: String
    var symbol: String?
    var tint: Color = .secondary
    @ViewBuilder let content: Content
    init(_ title: String, symbol: String? = nil, tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                if let symbol {
                    Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }.font(.headline)
                } else {
                    Text(title).font(.headline)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }
}

extension View {
    func cardBackground() -> some View {
        background(.background.secondary, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

struct Page<Content: View>: View {
    var maxWidth: CGFloat = 880
    @ViewBuilder let content: Content
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        let page = VStack(alignment: .leading, spacing: 16) { content }
            .padding(24)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        if snapshot { page } else { ScrollView { page } }
    }
}

extension EnvironmentValues {
    /// Rendering to an image (`Faktury --snapshot`): no scroll views, they render empty.
    @Entry var snapshot = false
}

struct Notice: View {
    let symbol: String, text: String
    var tint: Color = .orange
    var body: some View {
        Label { Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// A small colored capsule.
struct Pill: View {
    let text: String
    let color: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.13), in: .capsule)
        .fixedSize()
    }
}

/// The status of a document, the way Mail shows flags: one short word with a color.
struct StatusPill: View {
    let i: Invoice
    var body: some View {
        if i.isDraft { Pill(text: "Koncept", color: .secondary, symbol: "pencil") }
        else if i.status == .cancelled { Pill(text: "Zrušená", color: .secondary, symbol: "xmark") }
        else if i.kind == .creditNote { Pill(text: "Dobropis", color: .purple, symbol: "arrow.uturn.backward") }
        else if i.isPaid { Pill(text: i.creditedCents > 0 && i.paidCents == 0 ? "Dobropisovaná" : "Uhradená", color: .green, symbol: "checkmark") }
        else if i.isOverdue { Pill(text: "Po splatnosti \(Day.diff(i.dueDate, Day.today)) d", color: .red, symbol: "exclamationmark") }
        else { Pill(text: "Čaká na úhradu", color: .orange, symbol: "clock") }
    }
}

/// The subject's monogram in its color.
struct CompanyMark: View {
    let company: Company?
    var size: CGFloat = 22
    var body: some View {
        let c = Palette.color(company?.color ?? "gray")
        Text(initials)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(c.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
    var initials: String {
        let words = (company?.shortName ?? "?").split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

/// A text field for euros that keeps what you type and reports cents.
struct MoneyField: View {
    let title: String
    @Binding var cents: Int
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(title, text: $text)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = Money.plain(cents) }
            .onChange(of: cents) { _, v in if !focused { text = Money.plain(v) } }
            .onChange(of: text) { _, t in if let v = Money.parse(t), v != cents { cents = v } }
            .onChange(of: focused) { _, f in if !f { text = Money.plain(cents) } }
    }
}

/// Quantity with a decimal comma.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(title, text: $text)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = Money.quantity(value) }
            .onChange(of: value) { _, v in if !focused { text = Money.quantity(v) } }
            .onChange(of: text) { _, t in
                let s = t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
                if let v = Double(s), v != value { value = v }
            }
            .onChange(of: focused) { _, f in if !f { text = Money.quantity(value) } }
    }
}

extension Binding where Value == String {
    /// For `Day` strings edited with a DatePicker.
    var date: Binding<Date> {
        Binding<Date>(get: { Day.date(wrappedValue) }, set: { wrappedValue = Day.string($0) })
    }
}
