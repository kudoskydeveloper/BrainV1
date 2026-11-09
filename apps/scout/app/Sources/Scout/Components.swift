import SwiftUI

// The same building blocks as Ľudia, Fitness and Meetingy, so the series looks like one family.

enum Fmt {
    static let sk = Locale(identifier: "sk_SK")
    static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? day(s)
    }
    static func day(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
    static func date(_ d: Date) -> String {
        Calendar.current.isDate(d, equalTo: .now, toGranularity: .year)
            ? d.formatted(.dateTime.day().month(.abbreviated).locale(sk))
            : d.formatted(.dateTime.day().month(.abbreviated).year().locale(sk))
    }
    static func daysAgo(_ d: Date) -> Int { max(0, Calendar.current.dateComponents([.day], from: d, to: .now).day ?? 0) }
    /// 0 → "dnes", 1 → "včera", 5 → "pred 5 dňami", 45 → "pred 6 týždňami", 400 → "pred rokom".
    static func ago(_ days: Int?) -> String {
        guard let d = days else { return "nikdy" }
        switch d {
        case 0: return "dnes"
        case 1: return "včera"
        case 2..<14: return "pred \(d) dňami"
        case 14..<60: return "pred \(d / 7) týždňami"
        case 60..<365: let m = d / 30; return m == 1 ? "pred mesiacom" : "pred \(m) mesiacmi"
        default: let y = d / 365; return y == 1 ? "pred rokom" : "pred \(y) rokmi"
        }
    }
    static func money(_ v: Double?, _ currency: String = "EUR") -> String {
        guard let v else { return "–" }
        return v.formatted(.currency(code: currency).precision(.fractionLength(v.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2)).locale(sk))
    }
    /// "dnes", "zajtra", "o 3 dni", "pred 2 dňami" for a YYYY-MM-DD.
    static func due(_ s: String?) -> String {
        guard let s, let d = day(s) else { return "" }
        let n = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: d).day ?? 0
        switch n {
        case 0: return "dnes"
        case 1: return "zajtra"
        case -1: return "včera"
        case 2...: return n < 5 ? "o \(n) dni" : "o \(n) dní"
        default: return "pred \(-n) dňami"
        }
    }
    static func overdue(_ s: String?) -> Bool { guard let s, let d = day(s) else { return false }; return d < Calendar.current.startOfDay(for: .now) }
    /// 1 človek, 2–4 ľudia, 5+ ľudí.
    static func people(_ n: Int) -> String { n == 1 ? "1 človek" : (2...4).contains(n) ? "\(n) ľudia" : "\(n) ľudí" }
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

struct Card<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    var tint: Color = .secondary
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content
    init(_ title: String, symbol: String? = nil, tint: Color = .secondary, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.accessory = accessory(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let symbol {
                    Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }.font(.headline)
                } else {
                    Text(title).font(.headline)
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

struct Page<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        let page = VStack(alignment: .leading, spacing: 16) { content }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        if snapshot { page } else { ScrollView { page } }
    }
}

extension EnvironmentValues {
    /// Rendering to an image (`Scout --snapshot`): no scroll views, they render empty.
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

/// A round avatar with initials, colored by the name so a person always keeps the same color.
struct Avatar: View {
    let name: String
    var size: CGFloat = 28
    var initials: String {
        let w = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return (w.count >= 2 ? "\(w[0].prefix(1))\(w[w.count - 1].prefix(1))" : String(name.prefix(2))).uppercased()
    }
    static let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .mint, .cyan]
    static func color(for s: String) -> Color { colors[abs(s.lowercased().unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % colors.count] }
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Avatar.color(for: name).gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

struct TagChip: View {
    let tag: String
    var body: some View {
        Text(tag).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

func open(_ u: URL?) { if let u { NSWorkspace.shared.open(u) } }
func open(_ s: String?) { open(s.flatMap(URL.init(string:))) }

