import AppKit
import ReceptyCore
import SwiftUI

// The same building blocks as Fitness and Financie: stat tiles with a coloured caption, titled cards with a hairline edge,
// one page width.

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
    var minimum: CGFloat = 150
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 12, alignment: .top)], spacing: 12) { content }
    }
}

struct Card<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content
    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.accessory = accessory(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                accessory
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

struct ScrollPage<Content: View>: View {
    var maxWidth: CGFloat = 1100
    @ViewBuilder let content: Content
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        let page = VStack(alignment: .leading, spacing: 16) { content }
            .padding(20)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        if snapshot { page } else { ScrollView { page } }
    }
}

extension EnvironmentValues {
    /// Rendering to an image (`Recepty --snapshot`): no scroll views, they render empty.
    @Entry var snapshot = false
}

// MARK: Nutrition

/// The macros in Fitness's order and colours (protein red, carbs blue, fat yellow), so both apps read the same.
enum Macro: CaseIterable {
    case protein, carbs, fat
    var label: String { switch self { case .protein: "Bielkoviny"; case .fat: "Tuky"; case .carbs: "Sacharidy" } }
    var short: String { switch self { case .protein: "B"; case .fat: "T"; case .carbs: "S" } }
    var color: Color { switch self { case .protein: .red; case .carbs: .blue; case .fat: .yellow } }
    var symbol: String { switch self { case .protein: "fish.fill"; case .fat: "drop.fill"; case .carbs: "leaf.fill" } }
    func grams(_ n: Nutrients) -> Double { switch self { case .protein: n.protein; case .fat: n.fat; case .carbs: n.carbs } }
    func share(_ n: Nutrients) -> Double { let s = n.energySplit; switch self { case .protein: return s.protein; case .fat: return s.fat; case .carbs: return s.carbs } }
}

/// The energy colour, as Fitness's calories.
extension Color { static let energy = Color.orange }

/// Where the energy comes from: one bar split into protein, carbs and fat.
struct MacroBar: View {
    let n: Nutrients
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Macro.allCases, id: \.self) { m in
                    let w = max(0, g.size.width - 4) * m.share(n)
                    if w > 0 { Capsule().fill(m.color.gradient).frame(width: w) }
                }
            }
        }
        .frame(height: height)
        .background(Capsule().fill(.quaternary))
        .accessibilityLabel(Macro.allCases.map { "\($0.label) \(Int(($0.share(n) * 100).rounded())) %" }.joined(separator: ", "))
    }
}

/// A ring split by where the energy comes from, with the calories in the middle (like Fitness's "Dnes").
struct MacroRing: View {
    let n: Nutrients
    var size: CGFloat = 120
    var line: CGFloat = 13
    var body: some View {
        let gap = n.kcal > 0 ? 0.012 : 0
        ZStack {
            Circle().stroke(.quaternary, lineWidth: line)
            ForEach(Array(Macro.allCases.enumerated()), id: \.offset) { i, m in
                let start = Macro.allCases.prefix(i).map { $0.share(n) }.reduce(0, +)
                let end = start + m.share(n)
                if end - start > gap * 2 {
                    Circle().trim(from: start + gap, to: end - gap)
                        .stroke(m.color.gradient, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            VStack(spacing: 0) {
                Text(Fmt.number(n.kcal.rounded(), digits: 0)).font(.system(size: size * 0.22, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("kcal").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.kcal(n.kcal))")
    }
}

/// The ring plus a column per macro with its colour underline (Fitness's "Dnes" card).
struct NutritionSummary: View {
    let n: Nutrients
    var ring: CGFloat = 120
    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            MacroRing(n: n, size: ring)
            HStack(alignment: .top, spacing: 26) {
                ForEach(Macro.allCases, id: \.self) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.label).font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.macro(m.grams(n))).font(.title3.weight(.semibold)).monospacedDigit()
                        Capsule().fill(m.color.gradient).frame(width: 56, height: 4)
                        Text(n.kcal > 0 ? "\(Int((m.share(n) * 100).rounded())) % energie" : " ").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

/// A small fact in a capsule: "⏱ 45 min".
struct Pill: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.primary.opacity(0.06), in: Capsule())
    }
}

struct MacroLegend: View {
    let n: Nutrients
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Macro.allCases, id: \.self) { m in
                HStack(spacing: 5) {
                    Circle().fill(m.color).frame(width: 8, height: 8)
                    Text(m.label).foregroundStyle(.secondary)
                    Text("\(Int((m.share(n) * 100).rounded())) %").monospacedDigit()
                }
            }
        }
        .font(.caption)
    }
}

extension MatchStatus {
    var color: Color {
        switch self {
        case .matched: .green
        case .manual: .blue
        case .estimated: .orange
        case .skipped: .gray
        case .failed: .red
        case .pending: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .matched: "checkmark.circle.fill"
        case .manual: "hand.point.up.left.fill"
        case .estimated: "wand.and.stars"
        case .skipped: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .pending: "circle.dotted"
        }
    }
}

// MARK: Pictures

/// The recipe's photo, or a soft placeholder with a fork and knife.
struct RecipeImage: View {
    let path: String
    var corner: CGFloat = 12
    var body: some View {
        // The picture fills the frame it's given and is cut to it (a tall page doesn't stretch its container).
        Color.clear
            .overlay {
                if let img = Thumbs.image(path) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [.orange.opacity(0.35), .pink.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay { Image(systemName: "fork.knife").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.9)) }
                }
            }
            .clipShape(.rect(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

@MainActor
enum Thumbs {
    static var cache: [String: NSImage] = [:]
    static func image(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let i = cache[path] { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = i
        return i
    }
}

/// A small rounded tag.
struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
    }
}

extension Day {
    /// "Dnes", "Včera", "streda 4. 11." — for list sections.
    static func friendly(_ s: String) -> String {
        if s == today { return "Dnes" }
        if s == adding(-1, to: today) { return "Včera" }
        if s == adding(1, to: today) { return "Zajtra" }
        guard let d = date(s) else { return s }
        let f = DateFormatter(); f.locale = Locale(identifier: "sk_SK")
        f.dateFormat = s.prefix(4) == today.prefix(4) ? "EEEE d. M." : "EEEE d. M. yyyy"
        let t = f.string(from: d)
        return t.prefix(1).capitalized + t.dropFirst()
    }
    static func short(_ s: String) -> String {
        guard let d = date(s) else { return s }
        let f = DateFormatter(); f.locale = Locale(identifier: "sk_SK"); f.dateFormat = "EEE d. M."
        return f.string(from: d)
    }
}
