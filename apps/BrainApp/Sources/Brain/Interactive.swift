import AppKit
import SwiftUI

// The interactive parts of an answer and of the panel: proposal cards with buttons, option buttons, checklists, Brain's
// steps, the slash menu (commands and apps) and the quick actions of an empty panel.

// MARK: colors

extension Color {
    /// Brain's accent: a warm, saturated purple between the icon's purple → indigo gradient (solid, so it never looks faded).
    static let brainAccent = Color(red: 0.58, green: 0.33, blue: 0.91)
    /// The panel's own surface over the material: almost white in light mode, deep gray in dark.
    static let panelSurface = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 0.82) : NSColor(white: 1, alpha: 0.86)
    })
    /// Neutral buttons in the panel: solid light gray (dark gray in dark mode).
    static let panelChip = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.075)
    })
    /// Cards inside the panel (checklist, proposals): a touch darker than the surface, with a hairline.
    static let panelCard = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.035)
    })
}

extension ShapeStyle where Self == Color {
    static var brainAccent: Color { Color.brainAccent }
}

// MARK: apps you can point a question at with /slug

struct AppRef: Identifiable, Hashable {
    let slug: String, name: String, symbol: String, color: Color, hint: String
    var id: String { slug }
}

enum BrainApps {
    static let all: [AppRef] = [
        .init(slug: "courier", name: "Courier", symbol: "envelope.fill", color: .blue, hint: "e-mail v Courieri (courier cez call)"),
        .init(slug: "whatsapp", name: "WhatsApp", symbol: "phone.bubble.fill", color: .green, hint: "whatsapp_* nástroje"),
        .init(slug: "messenger", name: "Messenger", symbol: "bubble.left.and.bubble.right.fill", color: .blue, hint: "messenger_* cez Beeper (aj iné siete)"),
        .init(slug: "kalendar", name: "Kalendár", symbol: "calendar", color: .red, hint: "calendar_* (iCloud + Google)"),
        .init(slug: "todoist", name: "Todoist", symbol: "checklist", color: .red, hint: "Todoist (Kudosky alebo 10T podľa kontextu)"),
        .init(slug: "pripomienky", name: "Pripomienky", symbol: "bell.fill", color: .orange, hint: "reminders_* (Apple Pripomienky)"),
        .init(slug: "poznamky", name: "Apple Notes", symbol: "note.text", color: .yellow, hint: "apple_notes_*"),
        .init(slug: "subory", name: "Súbory", symbol: "folder.fill", color: .cyan, hint: "where_is, semantic_search, read_file"),
        .init(slug: "ludia", name: "Ľudia", symbol: "person.2.fill", color: .teal, hint: "people_overview, person, who"),
        .init(slug: "meetingy", name: "Meetingy", symbol: "person.wave.2.fill", color: .brainAccent, hint: "meetings, meeting_prep (Fathom)"),
        .init(slug: "hevy", name: "Hevy", symbol: "dumbbell.fill", color: .indigo, hint: "hevy_* (silový tréning)"),
        .init(slug: "strava", name: "Strava", symbol: "figure.run", color: .orange, hint: "strava_*"),
        .init(slug: "jedlo", name: "MyFitnessPal", symbol: "fork.knife", color: .green, hint: "myfitnesspal cez call"),
        .init(slug: "financie", name: "Financie", symbol: "eurosign.circle.fill", color: .mint, hint: "finance_overview a financie cez call"),
        .init(slug: "faktury", name: "Faktúry", symbol: "doc.text.fill", color: .brown, hint: "faktury cez call"),
        .init(slug: "daktela", name: "Daktela", symbol: "headphones", color: .blue, hint: "Daktela CRM cez call"),
        .init(slug: "linkedin", name: "LinkedIn", symbol: "link", color: .blue, hint: "linkedin cez call"),
        .init(slug: "trading", name: "Trading", symbol: "chart.line.uptrend.xyaxis", color: .green, hint: "trading_plan, market_overview, market-alerts"),
        .init(slug: "web", name: "Web", symbol: "globe", color: .gray, hint: "WebSearch / WebFetch"),
    ]
    static func find(_ cmd: String) -> AppRef? {
        guard cmd.hasPrefix("/") else { return nil }
        let k = String(cmd.dropFirst()).folding(options: .diacriticInsensitive, locale: nil).lowercased()
        return all.first { $0.slug == k }
    }
}

// MARK: slash menu

struct SlashItem: Identifiable, Hashable {
    let id: String          // what goes into the field, e.g. "/timer " or "/courier "
    let title: String
    let detail: String
    let symbol: String
    let color: Color
}

enum SlashMenu {
    static let commands: [SlashItem] = [
        .init(id: "/timer ", title: "/timer", detail: "neskôr, opakovane alebo pripomienka", symbol: "alarm", color: .pink),
        .init(id: "/repeat ", title: "/repeat", detail: "pýtať sa znova každých pár minút", symbol: "repeat", color: .brainAccent),
        .init(id: "/uloz ", title: "/uloz", detail: "uložiť dôležité z rozhovoru", symbol: "tray.and.arrow.down", color: .orange),
        .init(id: "/uprac ", title: "/uprac", detail: "upratať priečinok", symbol: "sparkles", color: .mint),
        .init(id: "/export", title: "/export", detail: "rozhovor do Markdownu", symbol: "square.and.arrow.up", color: .gray),
        .init(id: "/ucet", title: "/ucet", detail: "ktorý Claude účet", symbol: "person.crop.circle", color: .gray),
        .init(id: "/help", title: "/help", detail: "všetky príkazy", symbol: "questionmark.circle", color: .gray),
    ]

    /// Items for what is typed: "/" alone shows everything, "/co" filters; nothing once a space follows the word.
    static func items(for input: String) -> [SlashItem] {
        guard input.hasPrefix("/"), !input.contains(" "), !input.contains("\n") else { return [] }
        let q = String(input.dropFirst()).folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let apps = BrainApps.all.map { SlashItem(id: "/\($0.slug) ", title: "/\($0.slug)", detail: $0.name, symbol: $0.symbol, color: $0.color) }
        let all = apps + commands
        if q.isEmpty { return all }
        return all.filter { "\($0.title) \($0.detail)".folding(options: .diacriticInsensitive, locale: nil).lowercased().contains(q) }
    }
}

struct SlashMenuView: View {
    let items: [SlashItem]
    let selected: Int
    let pick: (SlashItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                        Button { pick(it) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: it.symbol).foregroundStyle(it.color).frame(width: 22)
                                Text(it.title).font(.system(size: 14, weight: .medium, design: .monospaced))
                                Text(it.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if i == selected { Text("↩").font(.caption).foregroundStyle(.tertiary) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(i == selected ? Color.brainAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(8)
            }
            .frame(height: min(CGFloat(items.count) * 33 + 16, 300))
            .onChange(of: selected) { _, i in proxy.scrollTo(i, anchor: .center) }
        }
    }
}

// MARK: a live session for the answer views (buttons act through it; the window's read-only transcript has none)

extension EnvironmentValues {
    @Entry var brainSession: Session? = nil
}

// MARK: proposal card

struct ProposalCard: View {
    let proposal: Proposal
    /// nil while undecided; true confirmed, false cancelled.
    let decided: Bool?
    let live: Bool
    /// Several proposals wait: the buttons only mark this one (sent together from the DecideBar).
    var multi = false
    /// What the user marked on it in that mode: true confirm, false cancel.
    var mark: Bool?
    @Environment(\.brainSession) var session
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(tint)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            let p = ProposalText(proposal.summary)
            Text(p.headline)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
            if !p.details.isEmpty && !p.collapsible {
                // the content itself (a message's text, an event): always shown
                Text(p.details)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !p.details.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    Text(p.details)
                        .font(.system(size: 11.5, design: p.raw ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(20)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                } label: {
                    Text("Podrobnosti").font(.caption).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            if decided == nil, live, let session {
                HStack(spacing: 6) {
                    if multi {
                        Button { session.marked[proposal.id] = mark == true ? nil : true } label: {
                            SlimChip(text: "Potvrdiť", symbol: mark == true ? "checkmark.circle.fill" : "circle", accent: mark == true)
                        }
                        Button { session.marked[proposal.id] = mark == false ? nil : false } label: {
                            SlimChip(text: "Zrušiť", symbol: mark == false ? "xmark.circle.fill" : nil)
                        }
                    } else {
                        // while Brain works on something else, the decision waits in the queue and goes right after
                        Button { session.decide(proposal, true) } label: { SlimChip(text: "Potvrdiť", symbol: "checkmark", accent: true) }
                        Button { session.input = "Zmeň návrh: " } label: { SlimChip(text: "Upraviť") }
                        Button { session.decide(proposal, false) } label: { SlimChip(text: "Zrušiť") }
                    }
                    Spacer()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.panelCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    var title: String {
        decided == true ? "Potvrdené" : decided == false ? "Zrušené" : mark == true ? "Potvrdíš" : mark == false ? "Zrušíš"
            : live ? "Čaká na tvoje potvrdenie" : "Návrh"
    }
    var icon: String { decided == true || mark == true ? "checkmark.circle.fill" : decided == false || mark == false ? "xmark.circle.fill" : "hand.raised.fill" }
    var tint: Color { decided == true || mark == true ? .green : decided == false || mark == false ? .secondary : .brainAccent }
}

/// Under several waiting proposals: confirm them all at once, or send what was marked on the cards in one go.
struct DecideBar: View {
    let open: [Proposal]
    let marked: [String: Bool]
    @Environment(\.brainSession) var session

    var body: some View {
        let chosen = open.compactMap { p in marked[p.id].map { (p, $0) } }
        HStack(spacing: 6) {
            Button { session?.decide(open.map { ($0, true) }) } label: { SlimChip(text: "Potvrdiť všetko (\(open.count))", symbol: "checkmark", accent: true) }
            Button { session?.decide(chosen) } label: {
                SlimChip(text: chosen.isEmpty ? "Odoslať výber" : "Odoslať výber (\(chosen.count))", symbol: "paperplane", accent: !chosen.isEmpty)
            }
            .disabled(chosen.isEmpty)
            Button { session?.decide(open.map { ($0, false) }) } label: { SlimChip(text: "Zrušiť všetko") }
            Spacer()
            Text(session?.running == true ? "Pošle sa, keď Brain dokončí" : "Označ na kartách, alebo naraz")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
    }
}

/// A proposal's text split for the card: the first line in words, the rest (arguments) as details. An older raw summary
/// ("todoist.reschedule-tasks({…})") becomes "Todoist: Reschedule tasks" with the JSON as details.
struct ProposalText {
    let headline: String
    let details: String
    let raw: Bool
    /// Only arguments (Brain's "· key: value" lines or raw JSON): folded away under "Podrobnosti".
    var collapsible: Bool { raw || details.components(separatedBy: "\n").allSatisfy { $0.hasPrefix("·") || $0.hasPrefix("  ") } }

    init(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let re = try! NSRegularExpression(pattern: #"^(💸 [^:]*: )?([\w-]+)\.([\w-]+)[( ](\{.*?)\)?$"#, options: [.dotMatchesLineSeparators])
        if let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) {
            let part = { (i: Int) in Range(m.range(at: i), in: t).map { String(t[$0]) } ?? "" }
            let server = part(2).replacingOccurrences(of: "-", with: " ").capitalized
            let tool = part(3).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            headline = "\(part(1))\(server): \(tool.prefix(1).uppercased() + tool.dropFirst())"
            details = part(4).replacingOccurrences(of: "},{", with: "},\n{")
            raw = true
        } else {
            let lines = t.components(separatedBy: "\n")
            headline = lines.first ?? t
            details = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            raw = false
        }
    }
}

// MARK: options: a last line "Možnosti: A | B | C" becomes buttons

struct OptionsRow: View {
    let options: [String]
    let live: Bool
    @Environment(\.brainSession) var session

    var body: some View {
        if live, let session {
            FlowRow(spacing: 8) {
                ForEach(options, id: \.self) { o in
                    Button { session.reply(o) } label: { SlimChip(text: o, accent: true) }.buttonStyle(.plain)
                }
            }
            .disabled(session.running)
        } else {
            Text("Možnosti: " + options.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// A small text button, the same as the panel's quick chips.
struct SlimChip: View {
    let text: String
    var symbol: String? = nil
    var accent = false
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(accent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.75)))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(accent ? Color.brainAccent : Color.panelChip, in: Capsule())   // flat and solid: clearly a button
        .contentShape(Capsule())
    }
}

/// Buttons that wrap onto more lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x + d.width > w, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += d.width + spacing; line = max(line, d.height)
        }
        return CGSize(width: w, height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x + d.width > b.maxX, x > b.minX { x = b.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += d.width + spacing; line = max(line, d.height)
        }
    }
}

// MARK: checklist: "- [ ] item" lines in the latest answer become toggles with one send button

struct ChecklistCard: View {
    let items: [(String, Bool)]
    @Environment(\.brainSession) var session
    @State var picked: Set<Int> = []
    @State var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                Button { if picked.contains(i) { picked.remove(i) } else { picked.insert(i) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: picked.contains(i) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked.contains(i) ? AnyShapeStyle(.brainAccent) : AnyShapeStyle(.tertiary))
                            .font(.system(size: 14))
                        Text(MarkdownView.inline(it.0)).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sent)
            }
            if let session, !sent {
                HStack {
                    Button { picked = picked.count == items.count ? [] : Set(items.indices) } label: {
                        SlimChip(text: picked.count == items.count ? "Odznačiť všetko" : "Označiť všetko")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { send(session) } label: { SlimChip(text: picked.isEmpty ? "Nič z toho" : "Pokračovať s \(picked.count)", accent: true) }
                        .buttonStyle(.plain)
                        .disabled(session.running)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.panelCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .onAppear { picked = Set(items.indices.filter { items[$0].1 }) }
    }

    func send(_ s: Session) {
        sent = true
        let yes = items.indices.filter { picked.contains($0) }.map { items[$0].0 }
        let no = items.indices.filter { !picked.contains($0) }.map { items[$0].0 }
        s.reply(yes.isEmpty ? "Nič z toho." : "Vybral som: " + yes.joined(separator: "; ") + (no.isEmpty ? "." : ". Nie: " + no.joined(separator: "; ") + "."))
    }
}

/// Splits an answer into the Markdown to show, its checklist items and its options line.
enum AnswerParts {
    static let task = try! NSRegularExpression(pattern: #"^\s*[-*] \[( |x|X)\] (.+)$"#)

    static func split(_ text: String) -> (markdown: String, tasks: [(String, Bool)], options: [String], base: String) {
        var lines = text.components(separatedBy: "\n")
        var options: [String] = []
        if let i = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let l = lines[i].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            for p in ["Možnosti:", "Options:"] where l.hasPrefix(p) {
                options = l.dropFirst(p.count).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !options.isEmpty { lines.remove(at: i) }
            }
        }
        var tasks: [(String, Bool)] = [], rest: [String] = []
        for l in lines {
            let r = NSRange(l.startIndex..., in: l)
            if let m = task.firstMatch(in: l, range: r), let t = Range(m.range(at: 2), in: l), let x = Range(m.range(at: 1), in: l) {
                tasks.append((String(l[t]), l[x] != " "))
            } else { rest.append(l) }
        }
        let base = lines.joined(separator: "\n")   // without the options line, checklist kept as text
        if tasks.count < 2 { return (base, [], options, base) }   // one task line is just text
        return (rest.joined(separator: "\n"), tasks, options, base)
    }
}

// MARK: steps

struct StepsView: View {
    let steps: [String]
    let working: Bool
    @State var open = false

    var body: some View {
        if working {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 8) {
                        if i == steps.count - 1 { NotchSpinner(size: 11, color: .secondary).frame(width: 14) }
                        else { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green).frame(width: 14) }
                        Text(s.replacingOccurrences(of: "…", with: "")).font(.callout)
                            .foregroundStyle(i == steps.count - 1 ? .primary : .secondary)
                    }
                }
            }
            .transition(.opacity)
        } else if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.smooth(duration: 0.2)) { open.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(open ? 90 : 0))
                        Text(steps.count == 1 ? "1 krok" : steps.count < 5 ? "\(steps.count) kroky" : "\(steps.count) krokov")
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        Label(s.replacingOccurrences(of: "…", with: ""), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }
}
