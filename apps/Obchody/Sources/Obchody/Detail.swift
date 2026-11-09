import SwiftUI

/// One client: who, billing, deals, tasks, notes, and around it mail from Courier and invoices from Faktúry.
struct AccountInspector: View {
    let pick: Pick
    @ObservedObject var store: Store
    let data: Overview?

    var body: some View {
        let b = data?.business(pick.business)
        Group {
            if let d = store.detail(pick.business, pick.account) {
                AccountDetailView(d: d, b: b)
            } else if let e = store.detailErrors["\(pick.business)|\(pick.account)"] {
                ContentUnavailableView {
                    Label("Detail sa nepodarilo načítať", systemImage: "exclamationmark.triangle")
                } description: { Text(e) } actions: { Button("Skúsiť znova") { store.loadDetail(pick.business, pick.account, force: true) } }
            } else {
                VStack(spacing: 10) {
                    if let a = b?.account(pick.account) ?? b?.leads.first(where: { $0.id == pick.account }).map({ Account(id: $0.id, name: $0.name) }) {
                        Text(a.name).font(.title3.weight(.semibold))
                    }
                    ProgressView().controlSize(.small)
                    Text("Kontakty, faktúry a maily…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { store.loadDetail(pick.business, pick.account) }
    }
}

struct AccountDetailView: View {
    let d: AccountDetail
    let b: Business?
    @State private var scout: [String: ScoutHit] = [:]
    @State private var scouting: Set<String> = []
    @Environment(\.snapshot) private var snapshot
    @EnvironmentObject private var editing: Editing

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            header
            if let b, !snapshot { actions(b) }
            if !d.deals.isEmpty {
                Card("Obchody", symbol: "rectangle.split.3x1.fill", tint: b?.tint ?? .accentColor) {
                    ForEach(d.deals) { deal in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(deal.title).font(.body.weight(.medium))
                                Spacer()
                                Text(deal.amount).font(.callout.weight(.semibold)).monospacedDigit()
                            }
                            Text(b?.stage(deal.stage)?.label ?? deal.stage ?? "").font(.caption).foregroundStyle(b?.stage(deal.stage)?.tint ?? .secondary)
                            if let n = deal.nextStep { Text("Ďalej\(deal.nextStepOn.map { " (\(Fmt.due($0)))" } ?? ""): \(n)").font(.caption).foregroundStyle(.secondary) }
                        }
                        .contentShape(.rect)
                        .contextMenu { if let b, let full = b.deals.first(where: { $0.id == deal.id }) { DealMenu(b: b, d: full) } }
                    }
                }
            }
            if !d.tasks.isEmpty {
                Card("Úlohy", symbol: "checklist", tint: .purple) {
                    ForEach(d.tasks) { t in
                        HStack {
                            if let b { TaskCheck(b: b, task: t.id, deal: t.dealId, account: d.id, overdue: Fmt.overdue(t.due)) }
                            Text(t.title)
                            Spacer()
                            Text(Fmt.due(t.due)).font(.caption).foregroundStyle(Fmt.overdue(t.due) ? .red : .secondary)
                        }
                    }
                }
            }
            if !d.contacts.isEmpty {
                Card("Kontakty", symbol: "person.2.fill", tint: .blue) {
                    if let dom = d.domain, !snapshot { Button("E-maily z webu") { Scout.open(company: dom) }.buttonStyle(.link).help("Všetky adresy z webu \(dom) v Scoute") }
                } content: {
                    ForEach(d.contacts) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Avatar(name: c.name, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(c.name).font(.body.weight(.medium))
                                    if c.primary { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                                }
                                if let p = c.position, !p.isEmpty { Text(p).font(.caption).foregroundStyle(.secondary) }
                                HStack(spacing: 10) {
                                    if let e = c.email { Button(e) { open("mailto:\(e)") }.buttonStyle(.link) }
                                    if let p = c.phone { Button(p) { open("tel:\(p.filter { $0.isNumber || $0 == "+" })") }.buttonStyle(.link) }
                                    if c.email == nil, let dom = d.domain, !snapshot, scout[c.id] == nil {
                                        if scouting.contains(c.id) { ProgressView().controlSize(.mini); Text("hľadám na \(dom)…").foregroundStyle(.secondary) }
                                        else { Button { find(c, dom) } label: { Label("Nájsť e-mail", systemImage: "binoculars") }.buttonStyle(.link) }
                                    }
                                }
                                .font(.caption)
                                if let hit = scout[c.id] { scoutResult(hit, for: c) }
                            }
                        }
                    }
                }
            }
            if !d.companies.isEmpty {
                Card("Fakturačné údaje", symbol: "doc.text.fill", tint: .teal) {
                    if let b, d.business == "10t" { Button("Upraviť") { editing.editor = .company(b, account: d.id, d.companies.first) }.buttonStyle(.link) }
                } content: {
                    ForEach(d.companies) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.legalName ?? d.name).font(.body.weight(.medium))
                            if let a = c.address { Text(a).font(.caption).foregroundStyle(.secondary) }
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                                if let v = c.registrationNo { GridRow { Text("IČO").foregroundStyle(.secondary); Text(v).textSelection(.enabled) } }
                                if let v = c.taxId { GridRow { Text("DIČ").foregroundStyle(.secondary); Text(v).textSelection(.enabled) } }
                                if let v = c.vatId { GridRow { Text("IČ DPH").foregroundStyle(.secondary); Text(v).textSelection(.enabled) } }
                                if let v = c.billingEmail { GridRow { Text("Faktúry na").foregroundStyle(.secondary); Text(v).textSelection(.enabled) } }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            invoicesCard
            if !d.mail.isEmpty {
                Card("Pošta v Courieri", symbol: "envelope.fill", tint: .blue) {
                    ForEach(d.mail.prefix(8), id: \.self) { m in
                        Button { openInCourier(m.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(m.subject ?? "(bez predmetu)").font(.callout.weight(m.unread == true ? .bold : .medium)).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.iso(m.date).map(Fmt.date) ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(m.snippet ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Otvoriť v Courieri")
                    }
                }
            }
            if !d.projects.isEmpty {
                Card("Projekty", symbol: "folder.fill", tint: .indigo) {
                    ForEach(d.projects) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            Text(p.status ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !d.notes_.isEmpty {
                Card("Poznámky a aktivita", symbol: "text.bubble.fill", tint: .gray) {
                    ForEach(Array(d.notes_.prefix(8).enumerated()), id: \.offset) { _, n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.body ?? "").font(.callout).textSelection(.enabled)
                            Text([Fmt.iso(n.at).map(Fmt.date), n.kind == "note" ? nil : n.kind].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        if snapshot { content } else { ScrollView { content } }
    }

    func find(_ c: AccountDetail.Contact, _ domain: String) {
        scouting.insert(c.id)
        Task {
            let r = await Scout.find(name: c.name, domain: domain)
            scouting.remove(c.id)
            switch r {
            case .success(let hit): scout[c.id] = hit
            case .failure(let e): scout[c.id] = ScoutHit(why: e.message)
            }
        }
    }

    @ViewBuilder func scoutResult(_ hit: ScoutHit, for c: AccountDetail.Contact) -> some View {
        if let e = hit.email {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "binoculars.fill").foregroundStyle(hit.tint)
                    Text(e).font(.callout.weight(.medium)).textSelection(.enabled)
                    Text(hit.label).font(.caption).foregroundStyle(hit.tint)
                }
                if hit.blocked == true { Text("V Nekontaktovať.").font(.caption).foregroundStyle(.red) }
                if let alt = hit.alternatives, !alt.isEmpty { Text("Alebo: \(alt.prefix(3).joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack(spacing: 10) {
                    if d.business == "10t", let b {
                        Button("Uložiť ku kontaktu") {
                            Store.shared.act(b.id, "contact_save", ["account": d.id, "id": c.id, "email": e], done: "E-mail uložený: \(c.name)", reload: d.id)
                        }
                    }
                    Button("Kopírovať") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e, forType: .string) }
                    Button("Napísať") { open("mailto:\(e)") }
                }
                .buttonStyle(.link).font(.caption)
                if d.business != "10t" { Text("Kuboard MCP nevie upraviť existujúci kontakt, adresu doplň v Kuboarde.").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(8)
            .background(hit.tint.opacity(0.08), in: .rect(cornerRadius: 8))
        } else {
            Text(hit.why ?? "Adresu sa nepodarilo nájsť.").font(.caption).foregroundStyle(.secondary)
        }
    }

    func actions(_ b: Business) -> some View {
        HStack(spacing: 8) {
            Button { editing.editor = .task(b, account: d.id, deal: nil) } label: { Label("Úloha", systemImage: "checklist") }
            Button { editing.editor = .note(b, account: d.id, deal: nil) } label: { Label("Poznámka", systemImage: "text.bubble") }
            Button { editing.editor = .deal(b, account: d.id, nil) } label: { Label("Obchod", systemImage: "plus.rectangle.on.rectangle") }
            Menu {
                Button("Kontakt…") { editing.editor = .contact(b, account: d.id) }
                if d.business == "10t" { Button("Fakturačné údaje…") { editing.editor = .company(b, account: d.id, d.companies.first) } }
            } label: { Label("Viac", systemImage: "ellipsis.circle") }
            .fixedSize()
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let l = d.legalName, l != d.name { Text(l).foregroundStyle(.secondary) }
                }
                Spacer()
                if let b { BusinessDot(b: b) }
            }
            HStack(spacing: 8) {
                if let l = d.lifecycle { Text(String.lifecycleLabel(l)).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: .capsule) }
                if let s = [d.segment, d.industry, d.employees].compactMap({ $0 }).first { Text(s).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let w = d.website { Button { open(w.hasPrefix("http") ? w : "https://\(w)") } label: { Label(d.domain ?? w, systemImage: "safari") }.buttonStyle(.link).font(.caption) }
            }
            if let n = d.notes, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder var invoicesCard: some View {
        if d.business == "10t" {
            let won = (b?.deals ?? []).filter { $0.accountId == d.id && b?.stage($0.stage)?.kind == "won" && ($0.value ?? 0) > 0 }
            Card("Faktúry", symbol: "eurosign.circle.fill", tint: .yellow) {
                if !won.isEmpty && !snapshot {
                    Menu {
                        ForEach(won) { deal in Button("\(deal.title) · \(deal.amount)") { Invoicing.draft(deal) } }
                    } label: { Label("Koncept z obchodu", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Koncept faktúry vo Faktúrach z vyhratého obchodu")
                }
            } content: {
                if d.invoices.isEmpty {
                    Text(d.companies.contains { $0.registrationNo != nil } ? "Vo Faktúrach zatiaľ nie je žiadna faktúra pre toto IČO." : "Bez IČO, faktúry sa nedajú spárovať.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(d.invoices, id: \.self) { i in
                    HStack {
                        Text(i.number ?? "koncept").font(.callout.weight(.medium))
                        Text(i.issue_date.flatMap(Fmt.day).map(Fmt.date) ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.money(i.total, i.currency ?? "EUR")).monospacedDigit()
                        Text(invoiceStatus(i.status)).font(.caption.weight(.semibold)).foregroundStyle(i.status == "overdue" ? .red : i.status == "paid" ? .green : .secondary)
                    }
                }
            }
        } else {
            let sub = b?.deals.first { $0.accountId == d.id && ($0.mrr ?? 0) > 0 }
            if sub != nil || !d.invoices.isEmpty {
                Card("Predplatné a faktúry", symbol: "eurosign.circle.fill", tint: .yellow) {
                    if let sub { Text("\(sub.seats.map { "\($0) sedadiel · " } ?? "")\(sub.amount)").font(.callout) }
                    ForEach(d.invoices, id: \.self) { i in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(i.number ?? "koncept").font(.callout.weight(.medium))
                                if let p = i.period { Text(p).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(Fmt.money(i.total, i.currency ?? "EUR")).monospacedDigit()
                            Text(invoiceStatus(i.status)).font(.caption.weight(.semibold)).foregroundStyle(i.status == "overdue" ? .red : i.status == "paid" ? .green : .secondary)
                            if let pdf = i.pdf, !snapshot { Button { open(pdf) } label: { Image(systemName: "doc.richtext") }.buttonStyle(.borderless).help("PDF") }
                        }
                    }
                    if d.invoices.isEmpty { Text("V Kuboarde zatiaľ žiadne faktúry pre tohto klienta.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    func invoiceStatus(_ s: String?) -> String {
        switch s {
        case "draft": "koncept"
        case "issued", "sent", "unpaid": "neuhradená"
        case "credited": "dobropis"
        case "overdue": "po splatnosti"
        case "paid": "uhradená"
        default: s ?? ""
        }
    }
}

extension Account {
    init(id: String, name: String) { self.init(id: id, ref: nil, name: name, lifecycle: nil, website: nil, domain: nil, updatedAt: nil) }
}
