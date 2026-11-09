import Charts
import SwiftUI

// MARK: Formatting

enum Fmt {
    static let sk = Locale(identifier: "sk_SK")
    private static let dayParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let dateTimeParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    static func day(_ s: String) -> Date { dayParser.date(from: String(s.prefix(10))) ?? .distantPast }
    static func dateTime(_ s: String) -> Date { dateTimeParser.date(from: String(s.prefix(16))) ?? day(s) }

    static func int(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0)).locale(sk)) }
    static func one(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...1)).locale(sk)) }
    static func signed(_ x: Double, _ unit: String) -> String { "\(x > 0 ? "+" : x < 0 ? "−" : "")\(one(abs(x))) \(unit)" }
    static func date(_ s: String) -> String { date(day(s)) }
    static func date(_ d: Date) -> String { d.formatted(.dateTime.day().month(.abbreviated).locale(sk)) }
    static func dateYear(_ d: Date) -> String { d.formatted(.dateTime.day().month(.abbreviated).year().locale(sk)) }
    static func weekday(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(sk)) }
    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour().minute().locale(sk)) }
    static func week(_ d: Date) -> String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: d) ?? d
        return "\(date(d)) – \(date(end))"
    }
    static func duration(_ m: Double) -> String {
        let h = Int(m.rounded()) / 60, mm = Int(m.rounded()) % 60
        return h > 0 ? (mm > 0 ? "\(h) h \(mm) min" : "\(h) h") : "\(mm) min"
    }
    static func hours(_ m: Double) -> String { m >= 60 ? "\(one(m / 60)) h" : "\(int(m)) min" }
    static func set(_ s: Overview.SetValue) -> String {
        switch (s.kg, s.reps, s.seconds) {
        case let (kg?, reps?, _) where kg > 0: "\(one(kg)) kg × \(int(reps))"
        case let (_, reps?, _): "\(int(reps)) opak."
        case let (_, _, sec?): duration(sec / 60)
        default: "–"
        }
    }
    static func logged(_ s: Overview.LoggedSet) -> String {
        set(Overview.SetValue(kg: s.kg, reps: s.reps, seconds: s.seconds))
    }
}

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
    /// Rendering to an image (`Fitness --snapshot`): no scroll views, they render empty.
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

/// The small change pill next to an exercise: green when it went up, red when down.
struct ChangeBadge: View {
    let value: Double
    let unit: String
    var body: some View {
        Text(Fmt.signed(value, unit))
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(value > 0 ? .green : value < 0 ? .red : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((value > 0 ? Color.green : value < 0 ? .red : .secondary).opacity(0.12), in: .capsule)
    }
}

/// The tooltip a chart shows above the selected bar or point.
struct ChartCallout: View {
    let title: String
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { Text($0).font(.callout.weight(.semibold)).monospacedDigit() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

/// Week labels on the x axis, thinned out so they don't overlap over a long period.
func weekAxis(_ count: Int) -> some AxisContent {
    AxisMarks(values: .stride(by: .weekOfYear, count: max(1, Int((Double(count) / 7).rounded(.up))))) { _ in
        AxisGridLine()
        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
    }
}

/// The week a hovered date falls in (charts with one bar per week).
func week<T>(_ items: [T], at date: Date?, _ start: (T) -> Date) -> T? {
    guard let date else { return nil }
    return items.first { let s = start($0); return date >= s && date < s.addingTimeInterval(7 * 86400) }
}

/// The point nearest to a hovered date (line charts).
func nearest<T>(_ items: [T], to date: Date?, _ day: (T) -> Date) -> T? {
    guard let date else { return nil }
    return items.min { abs(day($0).timeIntervalSince(date)) < abs(day($1).timeIntervalSince(date)) }
}

/// One row of an activity list: sport symbol, title, when, and the numbers that matter for that sport.
struct ActivityRow: View {
    let a: Overview.Activity
    @State private var hover = false

    var body: some View {
        Button { if let u = a.url { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 12) {
                Image(systemName: a.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(a.kind.color.gradient, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).lineLimit(1)
                    Text("\(Fmt.weekday(a.when)), \(Fmt.time(a.when)) · \(a.source == "hevy" ? "Hevy" : "Strava")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Image(systemName: "arrow.up.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .opacity(hover && a.url != nil ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(.rect)
            .background(.fill.tertiary.opacity(hover && a.url != nil ? 1 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(a.url == nil)
        .onHover { hover = $0 }
        .help(a.url != nil ? "Otvoriť na Strave" : "")
        .accessibilityElement(children: .combine)
    }

    var detail: String {
        var parts: [String] = []
        if let m = a.minutes, m > 0 { parts.append(Fmt.duration(m)) }
        if let k = a.km, k > 0 { parts.append("\(Fmt.one(k)) km") }
        if let v = a.volumeKg, v > 0 { parts.append("\(Fmt.int(v)) kg") }
        if let p = a.pace, (a.km ?? 0) > 0 { parts.append(p) }
        if let hr = a.avgHr { parts.append("\(Fmt.int(hr)) bpm") }
        return parts.joined(separator: "  ·  ")
    }
}

struct ActivityList: View {
    let items: [Overview.Activity]
    var body: some View {
        if items.isEmpty {
            Text("Za toto obdobie žiadne aktivity.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                    ActivityRow(a: a)
                    if i < items.count - 1 { Divider().padding(.leading, 52) }
                }
            }
        }
    }
}
