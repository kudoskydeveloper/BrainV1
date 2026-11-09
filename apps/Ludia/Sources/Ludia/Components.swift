import SwiftUI

// The same building blocks as Fitness and Meetingy, so the series looks like one family.

enum Fmt {
    static let sk = Locale(identifier: "sk_SK")
    private static let dayParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let minuteParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    static func day(_ s: String) -> Date { dayParser.date(from: String(s.prefix(10))) ?? .distantPast }
    /// "2026-11-06", "2026-11-06 14:58", "2026-11-06T13:00:00Z".
    static func dateTime(_ s: String) -> Date {
        if s.hasSuffix("Z"), let d = ISO8601DateFormatter().date(from: s.replacingOccurrences(of: ".000Z", with: "Z")) { return d }
        let t = s.replacingOccurrences(of: "T", with: " ")
        return minuteParser.date(from: String(t.prefix(16))) ?? day(s)
    }

    static func date(_ d: Date) -> String { d.formatted(.dateTime.day().month(.abbreviated).locale(sk)) }
    static func dateYear(_ d: Date) -> String {
        Calendar.current.isDate(d, equalTo: .now, toGranularity: .year) ? date(d) : d.formatted(.dateTime.day().month(.abbreviated).year().locale(sk))
    }
    static func weekday(_ d: Date) -> String { d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(sk)) }
    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour().minute().locale(sk)) }
    /// "Dnes", "Zajtra", "Včera", else the weekday and date.
    static func relativeDay(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "Dnes" }
        if c.isDateInTomorrow(d) { return "Zajtra" }
        if c.isDateInYesterday(d) { return "Včera" }
        let w = weekday(d)
        return w.prefix(1).capitalized + w.dropFirst()
    }
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
    /// "každé 2 týždne", "každý mesiac", "každých 60 dní".
    static func every(_ d: Int) -> String {
        switch d {
        case 7: "každý týždeň"
        case 14: "každé 2 týždne"
        case 30: "každý mesiac"
        case 60: "každé 2 mesiace"
        case 90: "každý štvrťrok"
        case 180: "každý polrok"
        case 365: "raz za rok"
        default: "každých \(d) dní"
        }
    }
    static let intervals = [7, 14, 30, 60, 90, 180, 365]
    static func phone(_ digits: String) -> String {
        guard digits.count == 12, digits.hasPrefix("421") || digits.hasPrefix("420") else { return "+" + digits }
        let d = Array(digits)
        return "+\(String(d[0..<3])) \(String(d[3..<6])) \(String(d[6..<9])) \(String(d[9..<12]))"
    }
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
    var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 12) { content } }
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
    /// Rendering to an image (`Ludia --snapshot`): no scroll views, they render empty.
    @Entry var snapshot = false
    /// Row actions of the people lists (Zlúčiť s…, Skryť), set by the window.
    @Entry var mergePerson: (Person) -> Void = { _ in }
    @Entry var hidePerson: (Person) -> Void = { _ in }
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

/// A round avatar with initials, colored by the person so they always keep the same color.
struct Avatar: View {
    let name: String
    let initials: String
    var size: CGFloat = 28
    init(_ p: Person, size: CGFloat = 28) { name = p.name; initials = p.initials; self.size = size }
    init(name: String, size: CGFloat = 28) {
        self.name = name; self.size = size
        let w = name.split(separator: " ").filter { $0.first?.isLetter == true }
        initials = (w.count >= 2 ? "\(w[0].prefix(1))\(w[w.count - 1].prefix(1))" : String(name.prefix(2))).uppercased()
    }
    static let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .mint, .cyan]
    var color: Color { Self.colors[abs(name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % Self.colors.count] }
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A small colored capsule: the business a person belongs to.
struct BusinessBadge: View {
    let b: Business
    var body: some View {
        Text(b.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(b.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(b.color.opacity(0.13), in: .capsule)
    }
}

/// The channel's small colored symbol.
struct ChannelIcon: View {
    let channel: String
    var body: some View {
        Image(systemName: ChannelStyle.symbol(channel)).foregroundStyle(ChannelStyle.color(channel)).help(channel)
    }
}

/// Asks Brain (its panel opens with the question).
func askBrain(_ q: String) {
    var c = URLComponents(string: "brain://ask")!
    c.queryItems = [URLQueryItem(name: "q", value: q)]
    if let u = c.url { NSWorkspace.shared.open(u) }
}

func open(_ s: String?) { if let s, let u = URL(string: s) { NSWorkspace.shared.open(u) } }
