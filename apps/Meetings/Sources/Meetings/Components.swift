import SwiftUI

// The same building blocks as the Fitness app, so the series looks like one family.

enum Fmt {
    static let sk = Locale(identifier: "sk_SK")
    private static let dayParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let minuteParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    /// "2026-11-06", "2026-11-06 14:58" or "2026-11-06T13:00:00" (local).
    static func dateTime(_ s: String) -> Date {
        let t = s.replacingOccurrences(of: "T", with: " ")
        return minuteParser.date(from: String(t.prefix(16))) ?? dayParser.date(from: String(t.prefix(10))) ?? .distantPast
    }
    static func iso(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) ?? (s.count >= 10 ? dateTime(s) : nil) }

    static func date(_ d: Date) -> String { d.formatted(.dateTime.day().month(.abbreviated).locale(sk)) }
    static func dateYear(_ d: Date) -> String {
        Calendar.current.isDate(d, equalTo: .now, toGranularity: .year) ? date(d) : d.formatted(.dateTime.day().month(.abbreviated).year().locale(sk))
    }
    static func weekday(_ d: Date) -> String { d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(sk)) }
    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour().minute().locale(sk)) }
    static func duration(_ m: Double) -> String {
        let h = Int(m.rounded()) / 60, mm = Int(m.rounded()) % 60
        return h > 0 ? (mm > 0 ? "\(h) h \(mm) min" : "\(h) h") : "\(mm) min"
    }
    /// "Dnes", "Zajtra", "Včera", else the weekday and date.
    static func relativeDay(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "Dnes" }
        if c.isDateInTomorrow(d) { return "Zajtra" }
        if c.isDateInYesterday(d) { return "Včera" }
        return weekday(d).prefix(1).capitalized + weekday(d).dropFirst()
    }
    /// Markdown bold markers and the like left out (for one-line previews).
    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "") }
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
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
            if let symbol {
                Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }.font(.headline)
            } else {
                Text(title).font(.headline)
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
    /// Rendering to an image (`Meetings --snapshot`): no scroll views, they render empty.
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

/// A round avatar with initials, colored by the person so they always keep the same color.
struct Avatar: View {
    let person: Person
    var size: CGFloat = 28
    static let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .mint, .cyan]
    var color: Color {
        let key = (person.email ?? person.display).lowercased()
        return Self.colors[abs(key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % Self.colors.count]
    }
    var body: some View {
        Text(person.initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// Up to `max` overlapping avatars, then "+N".
struct AvatarStack: View {
    let people: [Person]
    var max = 4
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(people.prefix(max).enumerated()), id: \.offset) { _, p in
                Avatar(person: p, size: size).overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            }
            if people.count > max {
                Text("+\(people.count - max)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, size * 0.4)
            }
        }
    }
}

/// A small colored capsule naming where a meeting belongs (10T, Kudosky, Súkromné).
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
