import SwiftUI
import HomeCore

// MARK: Building blocks

/// A number worth knowing at a glance: caption with a symbol, the value large, and a line of context.
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
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 12) { content }
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

/// The scrolling page every section is laid out on.
struct Page<Content: View>: View {
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
    /// Rendering to an image (`Home --snapshot`): no scroll views, they render empty.
    @Entry var snapshot = false
}

struct Notice: View {
    let symbol: String, text: String
    var tint: Color = .orange
    var body: some View {
        Label { Text(text).foregroundStyle(.primary) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

struct EmptyChart: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// A round tick button for a chore or shopping item.
struct CheckButton: View {
    let done: Bool
    var tint: Color = .accentColor
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? tint : Color.secondary.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Hotovo" : "Nehotovo")
    }
}

/// The initial of a member in a small coloured circle ("M", "S"); "Ktokoľvek" and "Striedame sa" get symbols.
struct WhoBadge: View {
    let who: String
    var body: some View {
        Group {
            switch who {
            case Who.anyone: Image(systemName: "person.2.fill").font(.system(size: 9, weight: .bold))
            case Who.takeTurns: Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9, weight: .bold))
            default: Text(String(who.prefix(1))).font(.system(size: 11, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Self.color(who).gradient, in: .circle)
        .help(Who.title(who))
    }

    static func color(_ who: String) -> Color {
        switch who {
        case Who.anyone, Who.takeTurns: .gray
        default: [Color.blue, .pink, .orange, .teal, .purple][abs(who.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 5]
        }
    }
}

/// A list row with a hover highlight, as in Fitness.
struct HoverRow<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(.rect)
            .background(.fill.tertiary.opacity(hover ? 1 : 0), in: .rect(cornerRadius: 8, style: .continuous))
            .onHover { hover = $0 }
    }
}

/// Rows separated by inset dividers.
struct Rows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var inset: CGFloat = 44
    @ViewBuilder let row: (Item) -> Row
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                row(item)
                if i < items.count - 1 { Divider().padding(.leading, inset) }
            }
        }
    }
}
