import SwiftUI

/// Asks Brain (its panel opens with the question).
func askBrain(_ q: String) {
    var c = URLComponents(string: "brain://ask")!
    c.queryItems = [URLQueryItem(name: "q", value: q)]
    if let u = c.url { NSWorkspace.shared.open(u) }
}

// MARK: Upcoming

struct UpcomingDetail: View {
    let u: Upcoming
    @ObservedObject var store: Store

    var body: some View {
        Page {
            header
            if let p = store.preps[u.id] {
                PrepView(p: p)
            } else if let e = store.prepErrors[u.id] {
                Notice(symbol: "exclamationmark.triangle.fill", text: "Prípravu sa nepodarilo pripraviť. \(e)")
                Button("Skúsiť znova") { store.loadPrep(u.id, force: true) }
            } else {
                Card("Príprava", symbol: "sparkles", tint: .purple) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Brain hľadá ľudí v Daktele, maily, WhatsApp, predchádzajúce meetingy a úlohy…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(u.title)
        .navigationSubtitle("\(Fmt.relativeDay(u.startDate)), \(Fmt.time(u.startDate))–\(Fmt.time(u.endDate))")
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button { askBrain("Priprav ma na meeting „\(u.title)“ (\(u.start.prefix(16).replacingOccurrences(of: "T", with: " "))): kto to je, čo sme riešili a na čo sa opýtať.") } label: {
                    Label("Spýtať sa Brainu", systemImage: "brain")
                }
                .help("Otvorí Brain s otázkou na prípravu")
            }
        }
        .task(id: u.id) { store.loadPrep(u.id) }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    Text(Fmt.time(u.startDate)).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text(Fmt.duration(u.minutes)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(minWidth: 76)
                .padding(.vertical, 10)
                .background(.red.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(u.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("\(Fmt.relativeDay(u.startDate)) · \(Fmt.time(u.startDate))–\(Fmt.time(u.endDate))").foregroundStyle(.secondary)
                    if let c = u.calendar { Label(c, systemImage: "calendar").font(.callout).foregroundStyle(.secondary) }
                    if let l = u.location { Label(l, systemImage: "mappin.and.ellipse").font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if let j = u.join {
                    Button { NSWorkspace.shared.open(j) } label: { Label("Pripojiť sa", systemImage: "video.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                        .help(j.absoluteString)
                }
            }
            Card("Účastníci", symbol: "person.2.fill", tint: .blue) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(u.people, id: \.self) { p in PersonRow(person: p, prep: store.preps[u.id]?.people.first { $0.email == p.email }) }
                }
            }
        }
    }
}

struct PersonRow: View {
    let person: Person
    let prep: Prep.PrepPerson?
    var body: some View {
        HStack(spacing: 10) {
            Avatar(person: Person(name: prep?.name.isEmpty == false ? prep?.name : person.name, email: person.email), size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(prep?.name.isEmpty == false ? prep!.name : person.display).font(.body.weight(.medium))
                Text([prep?.company ?? person.company, person.email].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let p = prep, !p.crm.isEmpty {
                Text("Daktela").font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.teal.opacity(0.13), in: .capsule)
                    .help(p.crm.compactMap { [$0.name, $0.account].compactMap { $0 }.joined(separator: ", ") }.joined(separator: "\n"))
            }
            if let e = person.email, let u = URL(string: "mailto:\(e)") {
                Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "envelope") }.buttonStyle(.borderless).help("Napísať \(e)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PrepView: View {
    let p: Prep
    var body: some View {
        if let a = p.agenda {
            Card("Agenda a poznámky z pozvánky", symbol: "text.alignleft", tint: .secondary) {
                Text(a).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        let personal = p.people.flatMap { $0.emails } + p.emails
        RowsCard(title: "Maily", symbol: "envelope.fill", tint: .blue, rows: dedupe(personal), empty: "S týmito ľuďmi ani firmou nie sú žiadne maily.")
        let wa = p.people.flatMap(\.whatsapp)
        if !wa.isEmpty { RowsCard(title: "WhatsApp", symbol: "message.fill", tint: .green, rows: wa, empty: "") }
        RowsCard(title: "Predchádzajúce meetingy", symbol: "clock.arrow.circlepath", tint: .orange, rows: p.earlier, empty: "Za posledný polrok žiadne.")
        if !p.notes.isEmpty { RowsCard(title: "Poznámky a nahrávky", symbol: "doc.text.fill", tint: .purple, rows: p.notes, empty: "") }
        RowsCard(title: "Otvorené úlohy", symbol: "checklist", tint: .red, rows: p.tasks, empty: "V Todoiste k tomu nie sú otvorené úlohy.")
    }
    func dedupe(_ rows: [Prep.Row]) -> [Prep.Row] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.title + ($0.date ?? "")).inserted }
    }
}

struct RowsCard: View {
    let title: String, symbol: String, tint: Color
    let rows: [Prep.Row]
    let empty: String
    var body: some View {
        Card(title, symbol: symbol, tint: tint) {
            if rows.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { i, r in
                        LinkRow(r: r)
                        if i < min(rows.count, 8) - 1 { Divider() }
                    }
                }
            }
        }
    }
}

struct LinkRow: View {
    let r: Prep.Row
    @State private var hover = false
    var body: some View {
        Button { if let u = r.url { NSWorkspace.shared.open(u) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.plain(r.title)).lineLimit(2)
                    if let d = r.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let d = r.date.flatMap(Fmt.iso) { Text(Fmt.dateYear(d)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                Image(systemName: "arrow.up.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).opacity(hover && r.url != nil ? 1 : 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 6)
            .contentShape(.rect)
            .background(.fill.tertiary.opacity(hover && r.url != nil ? 1 : 0), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(r.url == nil)
        .onHover { hover = $0 }
    }
}

// MARK: Recording

struct RecordingDetail: View {
    let r: Recording
    var busy = false
    var onMove: (Recording, Business) -> Void = { _, _ in }
    var onDelete: (Recording) -> Void = { _ in }

    var body: some View {
        Page {
            header
            if let e = r.error { Notice(symbol: "exclamationmark.triangle.fill", text: "Poznámku sa nepodarilo prečítať: \(e)") }
            if let s = r.section("purpose") { SectionCard(s: s, title: "Účel", symbol: "target", tint: .blue) }
            if let s = r.section("takeaways") { SectionCard(s: s, title: "Kľúčové zistenia", symbol: "lightbulb.fill", tint: .yellow) }
            if let s = r.section("action_items") { ActionItems(s: s) }
            if let s = r.section("next_steps") { SectionCard(s: s, title: "Ďalšie kroky", symbol: "arrow.right.circle.fill", tint: .green) }
            if let s = r.section("topics") { SectionCard(s: s, title: "Témy", symbol: "list.bullet.rectangle.fill", tint: .purple) }
            ForEach(r.sections.filter { ["other", "summary"].contains($0.kind) && !$0.items.isEmpty }) { s in
                SectionCard(s: s, title: s.kind == "summary" ? "Poznámka" : s.title, symbol: "text.alignleft", tint: .secondary)
            }
            if let n = r.transcriptLines, n > 0 {
                HStack {
                    Label("Prepis má \(Int(n)) riadkov", systemImage: "text.quote").foregroundStyle(.secondary)
                    Spacer()
                    Button("Otvoriť poznámku s prepisom") { NSWorkspace.shared.open(URL(fileURLWithPath: r.path)) }.buttonStyle(.link)
                }
                .font(.callout)
                .padding(.horizontal, 4)
            }
        }
        .navigationTitle(r.title)
        .navigationSubtitle("\(Fmt.weekday(r.day)) · \(r.kind.name)")
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                if let f = r.fathom.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(f) } label: { Label("Otvoriť vo Fathome", systemImage: "play.rectangle") }.help("Nahrávka vo Fathome")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) } label: { Label("Ukázať vo Finderi", systemImage: "folder") }
                Button { askBrain("Z meetingu „\(r.title)“ (\(r.date)) mi navrhni úlohy a ďalšie kroky. Poznámka: \(r.path)") } label: {
                    Label("Spýtať sa Brainu", systemImage: "brain")
                }
                .help("Otvorí Brain s otázkou na úlohy z tohto meetingu")
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                Menu {
                    ForEach(Business.allCases.filter { $0 != r.kind }) { b in
                        Button { onMove(r, b) } label: { Label(b.name, systemImage: b.symbol) }
                    }
                } label: { Label("Presunúť do projektu", systemImage: "tray.and.arrow.down") }
                .help("Presunúť nahrávku do iného projektu (teraz \(r.kind.name))")
                .disabled(busy)
                Button { onDelete(r) } label: { Label("Vymazať", systemImage: "trash") }
                    .help("Presunúť poznámku z meetingu do Koša")
                    .disabled(busy)
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BusinessBadge(b: r.kind)
                Text(Fmt.weekday(r.day) + (r.hasTime ? ", \(Fmt.time(r.day))" : "")).foregroundStyle(.secondary)
                if let m = r.minutes { Text("· \(Fmt.duration(m))").foregroundStyle(.secondary) }
            }
            .font(.callout)
            Text(r.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if !r.people.isEmpty {
                HStack(spacing: 8) {
                    AvatarStack(people: r.people, max: 5, size: 24)
                    Text(r.people.map(\.display).joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let rec = r.recordedOn { Text("Nahrané: \(rec)").font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.bottom, 4)
    }
}

struct SectionCard: View {
    let s: NoteSection
    let title: String, symbol: String, tint: Color
    var body: some View {
        Card(title, symbol: symbol, tint: tint) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(s.items.enumerated()), id: \.offset) { _, i in
                    if let h = i.heading {
                        Text(Fmt.markdown(h)).font(.subheadline.weight(.semibold)).padding(.top, 4)
                    } else if let t = i.text {
                        if i.para == true {
                            Text(Fmt.markdown(t)).font(.callout).fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(i.depth ?? 0 > 0 ? Color.secondary.opacity(0.5) : tint).frame(width: 5, height: 5)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                                Text(Fmt.markdown(t)).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, CGFloat(i.depth ?? 0) * 18)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
    }
}

/// Action items as a checklist (read-only: Brain already put the user's own ones into Todoist).
struct ActionItems: View {
    let s: NoteSection
    var body: some View {
        Card("Úlohy z meetingu", symbol: "checklist", tint: .red) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(s.items.filter { $0.text != nil }.enumerated()), id: \.offset) { _, i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: i.done == true ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(i.done == true ? .green : .secondary)
                        Text(Fmt.markdown(i.text!)).font(.callout).strikethrough(i.done == true).foregroundStyle(i.done == true ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Tvoje úlohy z meetingov Brain pridáva do Todoistu sám.").font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
            }
            .textSelection(.enabled)
        }
    }
}
