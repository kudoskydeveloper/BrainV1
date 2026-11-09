import AppKit
import SwiftUI

enum Folder: Hashable { case prospector, companies, people, blocked }

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var folder: Folder? = .prospector
    @State private var pick: String?
    @State private var lookup = false
    @State private var lookupDomain = ""
    @State private var lookupName = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $folder) {
                row("Firmy", "building.2.fill", .blue, store.data?.totals?.orgs ?? 0, .prospector)
                row("Prečítané weby", "globe", .teal, store.data?.companies.count ?? 0, .companies)
                row("Ľudia", "person.2.fill", .green, store.data?.totals?.people ?? store.data?.people.count ?? 0, .people)
                row("Nekontaktovať", "hand.raised.fill", .red, store.data?.blocked.count ?? 0, .blocked)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } content: {
            let wide = [.prospector, .people].contains(folder ?? .prospector)
            list.navigationSplitViewColumnWidth(min: wide ? 760 : 280, ideal: wide ? 980 : 330, max: wide ? 1600 : 440)
        } detail: {
            detail
        }
        .frame(minWidth: 1100, minHeight: 600)
        .onChange(of: folder) { _, _ in pick = nil }
        .overlay(alignment: .bottom) { EnrichBar().frame(maxWidth: 700).clipShape(.capsule).opacity(folder == .companies || folder == .blocked ? 1 : 0) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let b = store.busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(b).font(.callout).foregroundStyle(.secondary) }.padding(.horizontal, 6) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { lookup = true } label: { Label("Hľadať", systemImage: "binoculars") }
                    .help("Nájsť e-maily firmy alebo človeka (⌘F)")
                    .keyboardShortcut("f")
            }
        }
        .sheet(isPresented: $lookup) { LookupSheet(store: store, domain: $lookupDomain, name: $lookupName) { d, person in
            if person { folder = .people; pick = "\(lookupName)@\(d)" } else { folder = .companies; pick = d }
        } }
        .overlay(alignment: .bottom) { toastView }
        .onAppear {
            store.openMain = { [openWindow] in openWindow(id: "main") }
            applyPending()
        }
        .onChange(of: store.pendingSelection) { _, _ in applyPending() }
    }

    func row(_ t: String, _ s: String, _ c: Color, _ n: Int, _ f: Folder) -> some View {
        Label { Text(t) } icon: { Image(systemName: s).foregroundStyle(c) }.badge(n).tag(f)
    }

    @ViewBuilder var list: some View {
        switch folder ?? .prospector {
        case .prospector:
            ProspectorView(store: store, pick: $pick)
        case .companies:
            let rows = store.data?.companies ?? []
            Group {
                if rows.isEmpty {
                    ContentUnavailableView { Label("Zatiaľ žiadne firmy", systemImage: "building.2") } description: { Text("Zadaj doménu a Scout prečíta ich web.") } actions: { Button("Hľadať…") { lookup = true } }
                } else {
                    List(rows, selection: $pick) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.domain).font(.body.weight(.medium))
                            Text("\(c.emails) adries · \(c.people) ľudí · \(c.pattern.map { Confidence.pattern($0) } ?? "vzor nezistený")\(c.mx ? "" : " · bez pošty")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2).tag(c.domain)
                    }
                }
            }
            .navigationTitle("Prečítané weby")
        case .people:
            PeopleView(store: store, pick: $pick)
        case .blocked:
            let rows = store.data?.blocked ?? []
            Group {
                if rows.isEmpty {
                    ContentUnavailableView("Nikto", systemImage: "hand.raised", description: Text("Adresy a domény, ktorým sa nepíše. Pridáš ich v detaile firmy."))
                } else {
                    List(rows, id: \.self, selection: $pick) { b in
                        HStack { Image(systemName: b.contains("@") ? "envelope" : "globe").foregroundStyle(.secondary); Text(b) }.tag(b)
                            .contextMenu { Button("Odobrať z Nekontaktovať") { store.block(b, undo: true) } }
                    }
                }
            }
            .navigationTitle("Nekontaktovať")
        }
    }

    @ViewBuilder var detail: some View {
        VStack(spacing: 0) {
            if let e = store.error {
                Notice(symbol: "exclamationmark.triangle.fill", text: e, tint: .red).padding([.horizontal, .top], 16).onTapGesture { store.error = nil }
            }
            switch folder ?? .prospector {
            case .prospector:
                if let id = pick { OrgDetailView(id: id, store: store).id(id) }
                else { ContentUnavailableView("Vyber firmu", systemImage: "building.2", description: Text("Filtre vľavo, firma v tabuľke. ⌘-klikom vyberieš viac a pridáš ich do zoznamu.")) }
            case .companies:
                if let d = pick { CompanyDetail(domain: d, store: store).id(d) }
                else { ContentUnavailableView("Vyber firmu", systemImage: "building.2") }
            case .people:
                if let id = pick, let r = PeopleProspector.shared.rows.first(where: { $0.id == id }) { PersonRowDetail(r: r, store: store).id(id) }
                else if let id = pick, let p = store.lastPerson, p.id == id { PersonDetail(p: p, store: store) }
                else { ContentUnavailableView("Vyber človeka", systemImage: "person.crop.circle", description: Text("Filtre vľavo, človek v tabuľke.")) }
            case .blocked:
                if let b = pick {
                    Page {
                        Text(b).font(.title2.weight(.semibold))
                        Text("Na túto \(b.contains("@") ? "adresu" : "doménu") sa nepíše. Scout ju pri hľadaní označí.").foregroundStyle(.secondary)
                        Button("Odobrať z Nekontaktovať") { store.block(b, undo: true); pick = nil }
                    }
                } else { ContentUnavailableView("Nekontaktovať", systemImage: "hand.raised") }
            }
        }
    }

    @ViewBuilder var toastView: some View {
        if let t = store.toast {
            Label(t, systemImage: "checkmark.circle.fill")
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 18)
                .task(id: t) { try? await Task.sleep(for: .seconds(3)); if store.toast == t { store.toast = nil } }
        }
    }

    func applyPending() {
        guard let p = store.pendingSelection else { return }
        store.pendingSelection = nil
        let parts = p.split(separator: "/", maxSplits: 1).map(String.init)
        switch parts.first {
        case "people": folder = .people
        case "org" where parts.count > 1: folder = .prospector; DispatchQueue.main.async { pick = parts[1] }
        case "blocked": folder = .blocked
        case "company" where parts.count > 1: folder = .companies; pick = parts[1]; store.company(parts[1])
        case "person":
            if let n = store.pendingQuery["name"], let d = store.pendingQuery["domain"] {
                folder = .people; lookupName = n; lookupDomain = d
                store.person(name: n, domain: d) { p in pick = p.id }
            } else { lookup = true }
        default: folder = .prospector
        }
    }
}

struct LookupSheet: View {
    @ObservedObject var store: Store
    @Binding var domain: String
    @Binding var name: String
    let done: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Doména firmy", text: $domain, prompt: Text("firma.sk"))
                TextField("Meno človeka (voliteľné)", text: $name, prompt: Text("Ing. Jana Nováková"))
            } footer: {
                Text("Scout prečíta najviac 15 stránok ich webu (kontakt, tím, o nás, impressum, kariéra), rešpektuje robots.txt a nič neodosiela. S menom nájde adresu človeka: na webe, podľa vzoru kolegov alebo ako odhad.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Zrušiť") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(name.isEmpty ? "Prečítať web" : "Nájsť e-mail") {
                    let d = domain.trimmingCharacters(in: .whitespaces), n = name.trimmingCharacters(in: .whitespaces)
                    if n.isEmpty { store.company(d, fresh: false) { _ in done(d, false) } } else { store.person(name: n, domain: d) { _ in done(d, true) } }
                    dismiss()
                }
                .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct CompanyDetail: View {
    let domain: String
    @ObservedObject var store: Store

    var body: some View {
        Group {
            if let c = store.companies[domain] {
                Page {
                    HStack(alignment: .firstTextBaseline) {
                        Text(c.domain).font(.title2.weight(.semibold))
                        Spacer()
                        Button { store.company(domain, fresh: true) } label: { Label("Prečítať znova", systemImage: "arrow.clockwise") }.disabled(store.busy != nil)
                        Button { open("https://\(c.domain)") } label: { Label("Web", systemImage: "safari") }
                    }
                    HStack(spacing: 12) {
                        StatTile("Adresy", "\(c.emails.filter(\.own).count)", detail: c.emails.contains { !$0.own } ? "+ \(c.emails.filter { !$0.own }.count) cudzích" : nil, symbol: "envelope.fill", tint: .blue)
                        StatTile("Vzor", Confidence.pattern(c.pattern), detail: c.patternExamples.first.map { "\($0.email) = \($0.name.capitalized)" }, symbol: "person.text.rectangle", tint: .purple)
                        StatTile("Pošta", c.mx ? "prijíma" : "neprijíma", detail: "\(c.pagesRead) stránok\(c.skippedByRobots > 0 ? " · \(c.skippedByRobots) zakázané" : "")", symbol: "tray.fill", tint: c.mx ? .green : .red)
                    }
                    section("Ľudia", "person.fill", .green, c.emails.filter { $0.own && $0.kind == "person" })
                    section("Všeobecné", "building.2.fill", .blue, c.emails.filter { $0.own && $0.kind == "generic" })
                    section("Iné adresy firmy", "envelope.fill", .gray, c.emails.filter { $0.own && $0.kind == "other" })
                    section("Cudzie domény na ich webe", "arrow.up.right.square", .secondary, c.emails.filter { !$0.own })
                    if c.emails.isEmpty { Notice(symbol: "envelope.badge.shield.half.filled", text: "Na webe nie je žiadna adresa. Skús človeka podľa mena: Scout ju odhadne\(c.mx ? "" : ", ale doména neprijíma poštu").") }
                    Text("Prečítané \(Fmt.iso(c.crawledAt).map(Fmt.date) ?? ""). Pri každej adrese je stránka, kde bola (kvôli GDPR).").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Celú doménu do Nekontaktovať") { store.block(c.domain) }
                        Button("Vymazať všetko o doméne", role: .destructive) { store.forget(c.domain) }
                    }
                    .controlSize(.small)
                }
            } else {
                VStack(spacing: 10) { ProgressView().controlSize(.small); Text(store.busy ?? "Načítavam…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { store.company(domain) }
    }

    @ViewBuilder func section(_ title: String, _ symbol: String, _ tint: Color, _ list: [Company.Email]) -> some View {
        if !list.isEmpty {
            Card(title, symbol: symbol, tint: tint) {
                ForEach(list) { e in EmailRow(e: e, store: store) }
            }
        }
    }
}

struct EmailRow: View {
    let e: Company.Email
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(e.email).font(.body.weight(.medium)).textSelection(.enabled).strikethrough(e.blocked == true)
                if let n = e.name { Text(n).font(.caption).foregroundStyle(.secondary) }
                if e.blocked == true { Text("nekontaktovať").font(.caption2.weight(.semibold)).foregroundStyle(.red) }
                Spacer()
                Button { copy(e.email); store.toast = "Skopírované: \(e.email)" } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Kopírovať")
                Button { open("mailto:\(e.email)") } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("Napísať")
                Menu {
                    if let u = e.url { Button("Otvoriť stránku, kde je") { open(u) } }
                    Button(e.blocked == true ? "Odobrať z Nekontaktovať" : "Nekontaktovať") { store.block(e.email, undo: e.blocked == true) }
                    Button("Vymazať (GDPR)", role: .destructive) { store.forget(e.email) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if let c = e.context { Text("…\(c)…").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let u = e.url { Text(u.replacingOccurrences(of: "https://", with: "")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .padding(.vertical, 2)
    }
}

struct PersonDetail: View {
    let p: Person
    @ObservedObject var store: Store
    var body: some View {
        Page {
            HStack(spacing: 14) {
                Avatar(name: p.name, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.title2.weight(.semibold))
                    Text([p.role, p.company ?? p.domain].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                }
            }
            if let e = p.email {
                Card("E-mail", symbol: "envelope.fill", tint: Confidence.tint(p.confidence)) {
                    HStack {
                        Text(e).font(.title3.weight(.medium)).textSelection(.enabled)
                        Spacer()
                        Button("Kopírovať") { copy(e); store.toast = "Skopírované: \(e)" }
                        Button("Napísať") { open("mailto:\(e)") }
                    }
                    Label(Confidence.label(p.confidence), systemImage: p.confidence == "found" ? "checkmark.seal.fill" : p.confidence == "pattern" ? "person.text.rectangle" : "questionmark.circle")
                        .foregroundStyle(Confidence.tint(p.confidence))
                    if p.confidence != "found", let pat = p.pattern { Text("Vzor \(Confidence.pattern(pat))").font(.caption).foregroundStyle(.secondary) }
                    if let alt = p.alternatives, !alt.isEmpty { Text("Ďalšie možnosti: \(alt.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if p.blocked == true { Notice(symbol: "hand.raised.fill", text: "Táto adresa alebo doména je v Nekontaktovať.", tint: .red) }
                }
            } else {
                Notice(symbol: "envelope.badge.shield.half.filled", text: p.why ?? "Adresu sa nepodarilo nájsť.")
            }
            if let g = p.generic, !g.isEmpty {
                Card("Všeobecné adresy firmy", symbol: "building.2.fill", tint: .blue) {
                    ForEach(g, id: \.self) { e in HStack { Text(e).textSelection(.enabled); Spacer(); Button { copy(e) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless) } }
                }
            }
            if let d = p.domain { Button("Zobraziť firmu \(d)") { store.pendingSelection = "company/\(d)" }.buttonStyle(.link) }
        }
    }
}
