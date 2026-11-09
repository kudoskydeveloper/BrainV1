import FinancieCore
import SwiftUI

extension Color {
    /// The colours categories are stored with.
    static func named(_ s: String) -> Color {
        switch s {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        default: .gray
        }
    }
    static let categoryColors = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray"]
}

/// A round coloured icon, as in Wallet and Reminders.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// What a transaction looks like as an icon: its category, else what kind it is.
struct TxIcon: View {
    let t: Tx
    let category: TxCategory?
    var size: CGFloat = 30
    var body: some View {
        switch t.kind {
        case .transfer: IconBadge(symbol: "arrow.left.arrow.right", color: .gray, size: size)
        case .adjustment: IconBadge(symbol: "equal", color: .gray, size: size)
        default:
            if let c = category { IconBadge(symbol: c.symbol, color: .named(c.color), size: size) }
            else { IconBadge(symbol: t.kind == .income ? "arrow.down" : "arrow.up", color: t.kind == .income ? .green : .secondary, size: size) }
        }
    }
}

/// An amount: income green with a plus, expenses plain, transfers secondary.
struct Amount: View {
    let cents: Int
    var kind: TxKind? = nil
    var font: Font = .body
    var body: some View {
        Text(Money.string(cents, signed: cents > 0))
            .font(font.monospacedDigit())
            .foregroundStyle(kind == .transfer || kind == .adjustment ? Color.secondary : cents > 0 ? Color.green : Color.primary)
    }
}

// The same building blocks as Fitness: stat tiles with a coloured caption, titled cards with a hairline edge, one page width.

/// A number worth knowing at a glance: coloured caption with a symbol, the value large, a line of context.
struct StatTile: View {
    let title: String, value: String, detail: String?, symbol: String, tint: Color
    init(_ title: String, _ value: String, detail: String? = nil, symbol: String, tint: Color) {
        self.title = title; self.value = value; self.detail = detail; self.symbol = symbol; self.tint = tint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(14)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

struct StatGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], spacing: 12) { content }
    }
}

/// A titled card, the container for each chart and list.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
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

/// The scrolling page every overview is laid out on.
struct ScrollPage<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        let page = VStack(alignment: .leading, spacing: 16) { content }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        if snapshot { page } else { ScrollView { page } }
    }
}

extension EnvironmentValues {
    /// Rendering to an image (`Financie --snapshot`): no scroll views, they render empty.
    @Entry var snapshot = false
}

extension AccountType {
    var color: Color {
        switch self {
        case .bank: .blue
        case .savings: .green
        case .cash: .mint
        case .card: .orange
        case .investment: .purple
        }
    }
}

/// A text field for money ("1 234,50"); the value is cents, nil while it isn't a number.
struct MoneyField: View {
    let title: String
    @Binding var cents: Int?
    var large = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text("0,00"))
            .font(large ? .system(size: 28, weight: .semibold, design: .rounded).monospacedDigit() : .body.monospacedDigit())
            .focused($focused)
            .onAppear { if let c = cents, c != 0 { text = Money.string(abs(c)).replacingOccurrences(of: " €", with: "") } }
            .onChange(of: text) { _, t in cents = Money.parse(t).map(abs) }
    }
}

extension Day {
    /// "Dnes", "Včera", "streda 4. 11." — for list sections.
    static func friendly(_ s: String) -> String {
        if s == today { return "Dnes" }
        if s == adding(days: -1, to: today) { return "Včera" }
        if s == adding(days: 1, to: today) { return "Zajtra" }
        let d = date(s)
        let f = DateFormatter(); f.locale = Locale(identifier: "sk_SK")
        f.dateFormat = s.prefix(4) == today.prefix(4) ? "EEEE d. M." : "EEEE d. M. yyyy"
        return f.string(from: d).prefix(1).capitalized + f.string(from: d).dropFirst()
    }
}

func monthTitle(_ m: String) -> String {
    let n = Day.monthName(m, year: m.prefix(4) != Day.today.prefix(4))
    return n.prefix(1).capitalized + n.dropFirst()
}
