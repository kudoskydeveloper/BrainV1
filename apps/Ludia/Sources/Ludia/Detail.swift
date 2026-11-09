import SwiftUI

struct PersonDetail: View {
    let p: Person
    @ObservedObject var store: Store
    var onHide: () -> Void = {}
    var onMerge: () -> Void = {}
    /// The search's topic and what was said about it with this person (shown on top while searching).
    var topic: (String, TopicResult.Hit)? = nil
    @State private var confirmHide = false
    @State private var confirmSplit = false

    var d: Detail? { store.details[p.id] }

    var body: some View {
        Page {
            PersonHeader(p: p, store: store)
            if let (q, h) = topic {
                Card("„\(q)“ v komunikácii", symbol: "text.magnifyingglass", tint: .indigo, accessory: { Text("\(h.count)×").font(.caption).foregroundStyle(.secondary) }) {
                    Rows(items: h.hits.map { .init(title: $0.text, detail: $0.channel, date: $0.date, url: $0.url, symbol: ChannelStyle.symbol($0.channel == "Správy" ? "Messenger" : $0.channel)) })
                }
            }
            if p.isOverdue {
                Notice(symbol: "bell.badge.fill", text: "Ozvi sa: naposledy \(Fmt.ago(p.days)), chceš \(Fmt.every(p.every)).")
            }
            if let c = p.celebration {
                Notice(symbol: c.kind == "narodeniny" ? "birthday.cake.fill" : "gift.fill",
                       text: "\(c.kind == "narodeniny" ? "Narodeniny" : "Meniny") \(Fmt.relativeDay(Fmt.day(c.date)).lowercased()), \(Fmt.date(Fmt.day(c.date))).", tint: .pink)
            }
            LastContactCard(p: p)
            PromisesCard(p: p, promises: d?.promises, store: store)
            NoteCard(p: p, store: store)
            if let d { DetailCards(p: p, d: d) }
            else if let e = store.detailErrors[p.id] {
                Notice(symbol: "exclamationmark.triangle.fill", text: "Detail sa nepodarilo načítať. \(e)")
                Button("Skúsiť znova") { store.loadDetail(p.id, force: true) }
            } else {
                Card("Načítavam", symbol: "sparkles", tint: .purple) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(loadingText).foregroundStyle(.secondary)
                    }
                }
            }
            ContactCard(p: p, store: store)
        }
        .navigationTitle(p.name)
        .navigationSubtitle(p.lastLine)
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button { askBrain("Pomôž mi ozvať sa \(p.name)\(p.company.map { " (\($0))" } ?? ""): čo sme naposledy riešili, čo som sľúbil a návrh krátkej správy v mojom štýle.") } label: {
                    Label("Spýtať sa Brainu", systemImage: "brain")
                }
                .help("Otvorí Brain s otázkou, ako sa ozvať")
                Button { store.loadDetail(p.id, force: true) } label: { Label("Obnoviť detail", systemImage: "arrow.clockwise.circle") }
                Button { onMerge() } label: { Label("Zlúčiť s…", systemImage: "arrow.triangle.merge") }
                    .help("Tento človek je tu dvakrát? Zlúč ho s druhým záznamom")
                    .disabled(store.merging)
                if p.linked == true {
                    Button { confirmSplit = true } label: { Label("Rozdeliť", systemImage: "arrow.triangle.branch") }
                        .help("Vrátiť zlúčenie: záznamy sa rozdelia, ako ich spája Brain sám")
                        .disabled(store.merging)
                }
                Button { confirmHide = true } label: { Label("Skryť", systemImage: "eye.slash") }
                    .help("Skryť zo zoznamu (napr. firma alebo niekto, koho tu nechceš)")
            }
        }
        .confirmationDialog("Skryť \(p.name)?", isPresented: $confirmHide, titleVisibility: .visible) {
            Button("Skryť", role: .destructive) { onHide() }
            Button("Zrušiť", role: .cancel) {}
        } message: { Text("V Ľuďoch sa už neukáže. Vrátiš to v Brain dátach (data/ludia.json).") }
        .confirmationDialog("Rozdeliť \(p.name)?", isPresented: $confirmSplit, titleVisibility: .visible) {
            Button("Rozdeliť") { store.split(p) }
            Button("Zrušiť", role: .cancel) {}
        } message: { Text("Zlúčené záznamy sa znova ukážu zvlášť. Poznámka a sľuby zostanú pri tomto človeku.") }
        .overlay(alignment: .top) {
            if store.merging { Notice(symbol: "arrow.triangle.merge", text: "Zlučujem a načítavam znova…", tint: .blue).padding(16) }
        }
        .task(id: p.id) { store.loadDetail(p.id) }
    }
}

extension PersonDetail {
    /// What Brain is looking through for this person, from the channels they actually have.
    var loadingText: String {
        var parts: [String] = []
        if p.whatsapp != nil { parts.append("WhatsApp") }
        if !p.chats.isEmpty { parts.append(Set(p.chats.map(\.network)).sorted().joined(separator: ", ")) }
        if !p.emails.isEmpty { parts.append("maily") }
        parts.append("úlohy v Todoiste")
        if let c = store.data?.settings.crm, !p.emails.isEmpty, c.groups.contains(p.business) { parts.append(c.label) }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " a " + parts.last! : parts[0]
        return "Brain zbiera \(list)…"
    }
}

struct PersonHeader: View {
    let p: Person
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Avatar(p, size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        if p.linked == true { Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary).help("Zlúčený z viacerých záznamov") }
                    }
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(Business.allCases) { b in
                                Button { store.set(p, .init(business: b.rawValue)) } label: { Label(b.name, systemImage: b.symbol) }
                            }
                        } label: { BusinessBadge(b: p.biz) }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize()
                        .help(p.businessGuessed ? "Skupina odhadnutá podľa mailov a meetingov; klikni a zmeň" : "Zmeniť skupinu")
                        if let c = p.company { Text(c).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .font(.callout)
                }
                Spacer(minLength: 0)
                FollowButton(p: p, store: store)
            }
            HStack(spacing: 8) {
                if let ph = p.mainPhone {
                    Button { open("whatsapp://send?phone=\(ph)") } label: { Label("WhatsApp", systemImage: "phone.bubble.fill") }.tint(.green)
                    Button { open("sms:+\(ph)") } label: { Label("Správa", systemImage: "message.fill") }
                    Button { open("tel:+\(ph)") } label: { Label("Zavolať", systemImage: "phone.fill") }
                }
                if let e = p.emails.first {
                    Button { open("mailto:\(e)") } label: { Label("E-mail", systemImage: "envelope.fill") }
                }
                if let n = p.nextMeeting {
                    Button { open("meetings://upcoming") } label: { Label("\(Fmt.relativeDay(Fmt.dateTime(n.start))) meeting", systemImage: "calendar") }
                        .help(n.title)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.bottom, 2)
    }
}

/// The star: follow and how often to be in touch.
struct FollowButton: View {
    let p: Person
    @ObservedObject var store: Store
    var body: some View {
        Menu {
            ForEach(Fmt.intervals, id: \.self) { d in
                Button { store.set(p, .init(follow: true, every: d)) } label: {
                    if p.follow && p.every == d { Label(Fmt.every(d).capitalizedFirst, systemImage: "checkmark") } else { Text(Fmt.every(d).capitalizedFirst) }
                }
            }
            if p.follow {
                Divider()
                Button("Prestať sledovať", role: .destructive) { store.set(p, .init(follow: false)) }
            }
        } label: {
            Label(p.follow ? Fmt.every(p.every).capitalizedFirst : "Sledovať", systemImage: p.follow ? "star.fill" : "star")
        } primaryAction: {
            store.set(p, p.follow ? .init(follow: false) : .init(follow: true, every: store.data?.settings.everyDays ?? 60))
        }
        .fixedSize()
        .tint(p.follow ? .yellow : nil)
        .help(p.follow ? "Sleduješ: ozvi sa \(Fmt.every(p.every)). Klik prestane sledovať, šípka zmení interval." : "Sledovať: Ľudia ti pripomenú, keď sa dlho neozveš")
    }
}

extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }

struct LastContactCard: View {
    let p: Person
    var body: some View {
        Card("Posledný kontakt", symbol: "clock.fill", tint: .blue) {
            if p.channels.isEmpty {
                Text("Zatiaľ žiadna správa, mail ani meeting.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(p.channels.enumerated()), id: \.offset) { i, c in
                        HStack(spacing: 10) {
                            ChannelIcon(channel: c.channel).frame(width: 20)
                            Text(c.channel)
                            Spacer()
                            Text(detail(c)).font(.caption).foregroundStyle(.secondary)
                            Text(Fmt.dateYear(Fmt.day(c.date))).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 6)
                        if i < p.channels.count - 1 { Divider() }
                    }
                }
            }
        }
    }
    func detail(_ c: Person.Channel) -> String {
        switch c.channel {
        case "WhatsApp": p.whatsapp.map { "\($0.messages) správ" } ?? ""
        case "E-mail": p.mail.map { "\($0.sent) odoslaných · \($0.received) prijatých" } ?? ""
        case "Meeting": "\(p.meetings.count) nahraných"
        default: ""
        }
    }
}

struct PromisesCard: View {
    let p: Person
    let promises: [Promise]?
    @ObservedObject var store: Store
    @State private var text = ""
    @State private var showDone = false

    var body: some View {
        Card("Sľuby", symbol: "hand.raised.fill", tint: .red, accessory: {
            if (promises ?? []).contains(where: \.done) {
                Button(showDone ? "Skryť splnené" : "Ukázať splnené") { showDone.toggle() }.buttonStyle(.link).font(.caption)
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                let list = (promises ?? []).filter { showDone || !$0.done }
                ForEach(list) { q in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button { store.set(p, q.done ? .init(promiseUndo: q.id) : .init(promiseDone: q.id)) } label: {
                            Image(systemName: q.done ? "checkmark.circle.fill" : "circle").foregroundStyle(q.done ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(q.done ? "Vrátiť ako nesplnené" : "Splnené")
                        Text(q.text).strikethrough(q.done).foregroundStyle(q.done ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let dt = q.date { Text(Fmt.dateYear(Fmt.day(dt))).font(.caption).foregroundStyle(.tertiary) }
                    }
                    .contextMenu { Button("Vymazať", role: .destructive) { store.set(p, .init(promiseDelete: q.id)) } }
                }
                if promises == nil && p.promisesOpen > 0 { ProgressView().controlSize(.small) }
                TextField("Čo som sľúbil… (Enter pridá)", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        store.set(p, .init(promise: t))
                        text = ""
                    }
            }
        }
    }
}

struct NoteCard: View {
    let p: Person
    @ObservedObject var store: Store
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Card("Poznámka", symbol: "note.text", tint: .yellow, accessory: {
            if text != p.note {
                Button("Uložiť") { store.set(p, .init(note: text)) }.controlSize(.small).keyboardShortcut("s")
            }
        }) {
            TextField("Kto to je, kde sme sa spoznali, čo ho zaujíma…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...10)
                .focused($focused)
                .onAppear { text = p.note }
                .onChange(of: focused) { _, f in if !f, text != p.note { store.set(p, .init(note: text)) } }
        }
    }
}

/// Everything that comes with the detail: tasks, messages, e-mails, meetings, Brain notes.
struct DetailCards: View {
    let p: Person
    let d: Detail
    var body: some View {
        if let t = d.tasks, !t.isEmpty {
            Card("Úlohy v Todoiste", symbol: "checklist", tint: .red) {
                Rows(items: t.map { .init(title: $0.content, detail: $0.account + ($0.priority.map { " · \($0)" } ?? ""), date: $0.due, url: $0.url) })
            }
        }
        if let w = d.whatsapp, !w.isEmpty {
            Card("WhatsApp", symbol: "phone.bubble.fill", tint: .green) { Messages(msgs: Array(w.suffix(8))) }
        }
        ForEach(d.chats ?? [], id: \.id) { c in
            if !c.messages.isEmpty {
                Card(c.network, symbol: ChannelStyle.symbol(c.network), tint: ChannelStyle.color(c.network)) { Messages(msgs: Array(c.messages.suffix(6))) }
            }
        }
        if let m = d.mails, !m.isEmpty {
            Card("E-maily", symbol: "envelope.fill", tint: .blue, accessory: { Text("otvára v Courieri").font(.caption).foregroundStyle(.tertiary) }) {
                Rows(items: m.prefix(8).map { .init(title: $0.subject, detail: ($0.sent ? "Ja → " : "\($0.from ?? "") · ") + ($0.snippet ?? ""), date: $0.date, url: $0.url,
                                                    symbol: $0.sent ? "arrowshape.turn.up.right.fill" : "arrowshape.turn.up.left.fill") })
            }
        }
        if !p.meetings.isEmpty || p.nextMeeting != nil {
            Card("Meetingy", symbol: "person.2.wave.2.fill", tint: .orange) {
                Rows(items: (p.nextMeeting.map { [Rows.Item(title: $0.title, detail: "Najbližší", date: $0.start, url: "meetings://upcoming", symbol: "calendar")] } ?? [])
                     + p.meetings.map { .init(title: $0.title, detail: nil, date: $0.date, url: $0.path.map { URL(fileURLWithPath: $0).absoluteString }) })
            }
        }
        if let c = d.crm, !c.items.isEmpty {
            Card(c.label, symbol: "building.2.fill", tint: .teal) {
                Rows(items: c.items.map { .init(title: $0.name, detail: [$0.detail, $0.email].compactMap { $0 }.joined(separator: " · "), date: nil, url: nil) })
            }
        }
        if let n = d.notes, !n.isEmpty {
            Card("Z Brainu", symbol: "brain", tint: .purple) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(n, id: \.self) { x in
                        VStack(alignment: .leading, spacing: 2) {
                            if let t = x.topic { Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                            Text(x.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        let failed = (d.sources ?? [:]).filter { !$0.value.ok }
        if !failed.isEmpty {
            Text("Nedostupné: " + failed.map { "\($0.key) (\($0.value.error ?? ""))" }.sorted().joined(separator: ", "))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct Messages: View {
    let msgs: [Detail.Msg]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(msgs.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.me ? "Ja" : (m.who ?? "")).font(.caption.weight(.semibold)).foregroundStyle(m.me ? Color.accentColor : .secondary)
                        .frame(width: 70, alignment: .leading).lineLimit(1)
                    Text((m.text ?? "").replacingOccurrences(of: " ⏎ ", with: "\n")).font(.callout).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if let at = m.at { Text(Fmt.dateYear(Fmt.dateTime(at))).font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
                }
            }
        }
        .textSelection(.enabled)
    }
}


struct Rows: View {
    struct Item: Hashable { var title: String; var detail: String?; var date: String?; var url: String?; var symbol: String? = nil }
    let items: [Item]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, r in
                LinkRow(r: r)
                if i < items.count - 1 { Divider() }
            }
        }
    }
}

struct LinkRow: View {
    let r: Rows.Item
    @State private var hover = false
    var body: some View {
        Button { open(r.url) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let s = r.symbol { Image(systemName: s).font(.caption).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).lineLimit(2)
                    if let d = r.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let d = r.date { Text(Fmt.dateYear(Fmt.dateTime(d))).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
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

struct ContactCard: View {
    let p: Person
    var store: Store? = nil
    @State private var editing = false

    var body: some View {
        Card("Kontakt", symbol: "person.text.rectangle.fill", tint: .secondary) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(p.phones, id: \.self) { ph in line("Telefón", Fmt.phone(ph)) }
                ForEach(p.emails, id: \.self) { e in line("E-mail", e) }
                GridRow {
                    Text("Narodeniny").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        if let b = p.birthday {
                            Text(b.hasPrefix("0000") ? Fmt.date(Fmt.day("2000" + b.dropFirst(4))) : Fmt.dateYear(Fmt.day(b)) + " (\(age(b)) r.)")
                            if let s = p.birthdaySource { Text(s == "ručne" ? "zadané ručne" : "z \(s)").font(.caption).foregroundStyle(.tertiary) }
                        } else {
                            Text("nevieme").foregroundStyle(.tertiary)
                        }
                        if store != nil {
                            Button(p.birthday == nil ? "Pridať" : "Upraviť") { editing = true }.buttonStyle(.link).font(.caption)
                                .popover(isPresented: $editing, arrowEdge: .bottom) { BirthdayEditor(p: p) { store?.set(p, .init(birthday: $0)) } }
                        }
                    }
                }
                if p.aliases.count > 1 { line("Aj ako", p.aliases.filter { $0 != p.name }.joined(separator: ", ")) }
                if !p.groups.isEmpty { line("Skupiny", p.groups.joined(separator: ", ")) }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }
    func age(_ b: String) -> Int { Calendar.current.dateComponents([.year], from: Fmt.day(b), to: .now).year ?? 0 }
    func line(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v)
        }
    }
}

/// Day and month (and the year if you know it) of a birthday you enter by hand; "" removes yours.
struct BirthdayEditor: View {
    let p: Person
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day = 1
    @State private var month = 1
    @State private var knowYear = false
    @State private var year = 1990
    static let months = ["január", "február", "marec", "apríl", "máj", "jún", "júl", "august", "september", "október", "november", "december"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Narodeniny: \(p.name)").font(.headline)
            HStack {
                Picker("Deň", selection: $day) { ForEach(1...31, id: \.self) { Text("\($0).").tag($0) } }.labelsHidden().frame(width: 70)
                Picker("Mesiac", selection: $month) { ForEach(1...12, id: \.self) { Text(Self.months[$0 - 1]).tag($0) } }.labelsHidden().frame(width: 120)
            }
            HStack {
                Toggle("Rok", isOn: $knowYear).toggleStyle(.checkbox)
                TextField("", value: $year, format: .number.grouping(.never)).frame(width: 70).disabled(!knowYear)
            }
            HStack {
                if p.birthdaySource == "ručne" { Button("Odstrániť", role: .destructive) { save(""); dismiss() } }
                Spacer()
                Button("Zrušiť") { dismiss() }
                Button("Uložiť") { save(String(format: "%04d-%02d-%02d", knowYear ? year : 0, month, day)); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            guard let b = p.birthday, b.count >= 10 else { return }
            let parts = b.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 { year = parts[0] == 0 ? 1990 : parts[0]; knowYear = parts[0] != 0; month = parts[1]; day = parts[2] }
        }
    }
}

/// A birthday or name day whose contacts aren't in the list (no messages yet): who, and a WhatsApp button for each.
struct CelebrationDetail: View {
    let c: Celebration
    var onAssign: () -> Void = {}
    var body: some View {
        Page {
            HStack(spacing: 12) {
                Image(systemName: c.isBirthday ? "birthday.cake.fill" : "gift.fill").font(.largeTitle).foregroundStyle(.pink)
                VStack(alignment: .leading) {
                    Text(c.contacts.count == 1 ? c.contacts[0].name ?? c.who : c.who).font(.title2.weight(.semibold))
                    Text("\(c.label) · \(Fmt.relativeDay(c.day))").foregroundStyle(.secondary)
                }
            }
            if c.contacts.isEmpty {
                Card("Z kalendára \(c.source ?? "")", symbol: "calendar", tint: .pink) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tieto narodeniny sa nespárovali so žiadnym človekom v Ľuďoch. Ak vieš, koho sú, priraď ich: Brain si meno zapamätá a narodeniny sa ukážu aj v jeho detaile.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button { onAssign() } label: { Label("Priradiť k človeku…", systemImage: "person.crop.circle.badge.plus") }
                    }
                }
            } else {
            Card(c.contacts.count == 1 ? "Kontakt" : "Kontakty s týmto menom", symbol: "person.crop.circle.fill", tint: .pink) {
                VStack(spacing: 8) {
                    ForEach(c.contacts, id: \.self) { k in
                        HStack(spacing: 10) {
                            Avatar(name: k.name ?? c.who, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(k.name ?? c.who)
                                if let co = k.company { Text(co).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let ph = k.phone.map({ $0.filter(\.isNumber) }).map({ $0.hasPrefix("0") ? "421" + $0.dropFirst() : $0 }), !ph.isEmpty {
                                Button { open("whatsapp://send?phone=\(ph)") } label: { Label("Zablahoželať", systemImage: "phone.bubble.fill") }
                                    .buttonStyle(.bordered).tint(.green)
                            }
                        }
                    }
                }
            }
            }
        }
        .navigationTitle(c.who)
        .navigationSubtitle(c.label)
    }
}
