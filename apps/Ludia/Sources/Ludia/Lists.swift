import SwiftUI

/// People as rows; grouped by when you were last in touch (this week, this month, …) or as given.
struct PeopleList: View {
    let people: [Person]
    @Binding var selection: String?
    let title: String
    var grouped = true
    let empty: (String, String, String)
    @Environment(\.mergePerson) private var onMerge
    @Environment(\.hidePerson) private var onHide

    var sections: [(String, [Person])] {
        guard grouped else { return [("", people)] }
        let bands: [(String, ClosedRange<Int>)] = [("Tento týždeň", 0...6), ("Tento mesiac", 7...30), ("Posledné 3 mesiace", 31...90),
                                                   ("Tento rok", 91...365), ("Dávnejšie", 366...Int.max - 1)]
        var out = bands.map { b in (b.0, people.filter { $0.days.map(b.1.contains) == true }) }
        out.append(("Bez kontaktu", people.filter { $0.days == nil }))
        return out.filter { !$0.1.isEmpty }
    }

    var body: some View {
        Group {
            if people.isEmpty {
                ContentUnavailableView(empty.0, systemImage: empty.1, description: Text(empty.2))
            } else {
                List(selection: $selection) {
                    ForEach(sections, id: \.0) { title, list in
                        if title.isEmpty {
                            ForEach(list) { p in row(p) }
                        } else {
                            Section(title) { ForEach(list) { p in row(p) } }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(people.count == 1 ? "1 človek" : (2...4).contains(people.count) ? "\(people.count) ľudia" : "\(people.count) ľudí")
    }
}

extension PeopleList {
    func row(_ p: Person) -> some View {
        PersonRow(p: p).tag(p.id).contextMenu {
            Button { onMerge(p) } label: { Label("Zlúčiť s…", systemImage: "arrow.triangle.merge") }
            Divider()
            Button(role: .destructive) { onHide(p) } label: { Label("Skryť", systemImage: "eye.slash") }
        }
    }
}

struct PersonRow: View {
    let p: Person
    var body: some View {
        HStack(spacing: 10) {
            Avatar(p, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(p.name).font(.body.weight(.medium)).lineLimit(1)
                    if p.follow { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).help("Sleduješ \(Fmt.every(p.every))") }
                    if p.celebration != nil { Image(systemName: "gift.fill").font(.caption2).foregroundStyle(.pink).help("Čoskoro oslavuje") }
                }
                Text(p.company ?? p.biz.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    if let l = p.last { ChannelIcon(channel: l.channel).font(.caption2) }
                    Text(p.lastLine).foregroundStyle(p.isOverdue ? .orange : .secondary)
                }
                .font(.caption).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(Array(Set(p.channels.map(\.channel))).sorted(), id: \.self) { c in ChannelIcon(channel: c) }
                }
                .font(.caption2)
                if p.promisesOpen > 0 {
                    Label("\(p.promisesOpen)", systemImage: "hand.raised.fill").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                        .help("Otvorené sľuby")
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Birthdays and name days ahead (14 days to a year, picked at the top); by day, or by month for longer ranges.
/// A celebration matched to a person selects that person.
struct CelebrationList: View {
    let data: Overview
    @Binding var selection: String?
    @Binding var days: Int
    static let ranges = [(14, "2 týždne"), (30, "Mesiac"), (90, "3 mesiace"), (365, "Rok")]

    var shown: [Celebration] {
        let end = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: .now))!
        return data.celebrations.filter { $0.day < end }
    }
    var groups: [(String, [Celebration])] {
        var order: [String] = [], g: [String: [Celebration]] = [:]
        for c in shown {
            let k = days > 30 ? c.day.formatted(.dateTime.month(.wide).year().locale(Fmt.sk)).capitalizedFirst : Fmt.relativeDay(c.day)
            if g[k] == nil { order.append(k) }
            g[k, default: []].append(c)
        }
        return order.map { ($0, g[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Rozsah", selection: $days) { ForEach(Self.ranges, id: \.0) { Text($0.1).tag($0.0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.vertical, 8)
            if shown.isEmpty {
                ContentUnavailableView("Žiadne oslavy", systemImage: "gift", description: Text("V tomto období nikto neoslavuje."))
            } else {
                List(selection: $selection) {
                    ForEach(groups, id: \.0) { title, list in
                        Section(title) {
                            ForEach(list) { c in
                                if c.people.isEmpty {
                                    CelebrationRow(c: c, person: nil, showDate: days > 30).tag("c|" + c.id)
                                } else {
                                    ForEach(c.people, id: \.self) { id in CelebrationRow(c: c, person: data.person(id), showDate: days > 30).tag(id) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Oslavy")
        .navigationSubtitle("\(shown.filter(\.isBirthday).count) narodenín · \(shown.filter { !$0.isBirthday }.count) menín")
    }
}

struct CelebrationRow: View {
    let c: Celebration
    let person: Person?
    var showDate = false
    var name: String { person?.name ?? (c.contacts.count == 1 ? c.contacts[0].name ?? c.who : c.who) }
    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(name: name, size: 34)
                Image(systemName: c.isBirthday ? "birthday.cake.fill" : "gift.fill").font(.system(size: 11)).foregroundStyle(.white)
                    .padding(3).background(.pink, in: .circle).offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).lineLimit(1)
                Text([showDate ? Fmt.date(c.day) : nil, person == nil && c.contacts.count > 1 ? "\(c.label) · \(c.contacts.count) kontaktov" : c.label,
                      person == nil && c.contacts.isEmpty ? "nespárované" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Searching: people by name, company, e-mail or phone, and below, who you talked with about it (mail, chats, meetings).
struct SearchList: View {
    let query: String
    let names: [Person]
    let topic: TopicResult?
    let loading: Bool
    let data: Overview
    @Binding var selection: String?
    @Environment(\.mergePerson) private var onMerge
    @Environment(\.hidePerson) private var onHide

    var topicPeople: [(TopicResult.Hit, Person)] {
        (topic?.query == query.trimmingCharacters(in: .whitespaces) ? topic?.people ?? [] : []).compactMap { h in data.person(h.id).map { (h, $0) } }
    }

    var body: some View {
        List(selection: $selection) {
            if !names.isEmpty {
                Section("Ľudia") { ForEach(names) { p in PersonRow(p: p).tag(p.id) } }
            }
            Section {
                ForEach(topicPeople.filter { t in !names.contains { $0.id == t.1.id } }, id: \.0.id) { h, p in TopicRow(hit: h, p: p).tag(p.id) }
                ForEach(topicPeople.filter { t in names.contains { $0.id == t.1.id } }, id: \.0.id) { h, p in TopicRow(hit: h, p: p).tag("t|" + p.id) }
            } header: {
                HStack {
                    Text("Písali ste si o „\(query)“")
                    if loading { ProgressView().controlSize(.mini) }
                }
            } footer: {
                if !loading && topicPeople.isEmpty && query.count >= 3 { Text("V mailoch, správach ani meetingoch nič.").font(.caption).foregroundStyle(.secondary) }
                if query.count < 3 { Text("Od 3 znakov hľadám aj v mailoch, správach a meetingoch.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onChange(of: selection) { _, s in if let s, s.hasPrefix("t|") { selection = String(s.dropFirst(2)) } }
        .navigationTitle("Hľadanie")
        .navigationSubtitle("\(names.count) podľa mena · \(topicPeople.count) v komunikácii")
    }
}

struct TopicRow: View {
    let hit: TopicResult.Hit
    let p: Person
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(p, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(p.name).font(.body.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text("\(hit.count)×").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let l = hit.hits.first {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ChannelIcon(channel: l.channel == "Správy" ? "Messenger" : l.channel).font(.caption2)
                        Text(l.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Pick a person (assigning a birthday from a calendar): look-alikes of `suggest` first, then search.
struct PersonPicker: View {
    let title: String
    let note: String
    let people: [Person]
    let suggest: String
    let onPick: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: String?

    var list: [Person] {
        let q = (query.isEmpty ? suggest : query).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = q.split(separator: " ").map(String.init)
        return people.filter { p in
            let n = p.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            return words.contains { w in w.count > 2 && (n.contains(w) || p.aliases.contains { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(w) }) }
        }.prefix(40).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            TextField("Hľadať človeka", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 20)
            List(selection: $chosen) { ForEach(list) { MergeRow(x: $0).tag($0.id) } }
                .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Priradiť") { if let p = people.first(where: { $0.id == chosen }) { onPick(p); dismiss() } }
                    .keyboardShortcut(.defaultAction).disabled(chosen == nil)
            }
            .padding(20)
        }
        .frame(width: 460, height: 500)
    }
}
