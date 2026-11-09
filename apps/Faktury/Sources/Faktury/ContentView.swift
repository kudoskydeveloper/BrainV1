import FakturyCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    var body: some View {
        Group {
            if model.companies.isEmpty {
                Welcome(model: model)
            } else {
                NavigationSplitView {
                    Sidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
                } content: {
                    middle
                        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
                } detail: {
                    detail
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .environment(\.locale, Locale(identifier: "sk_SK"))
        .searchable(text: $query, placement: .toolbar, prompt: "Hľadať číslo, odberateľa, položku")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(model.companies) { c in
                        Button { model.newInvoice(kind: .invoice, companyId: c.id) } label: { Text("Faktúra – \(c.shortName)") }
                    }
                    Divider()
                    ForEach(model.companies) { c in
                        Button { model.newInvoice(kind: .proforma, companyId: c.id) } label: { Text("Zálohová faktúra – \(c.shortName)") }
                    }
                    if !model.templates.isEmpty {
                        Section("Zo šablóny") {
                            ForEach(model.templates) { t in Button { model.newInvoice(fromTemplate: t.id) } label: { Text(t.name) } }
                        }
                    }
                } label: {
                    Label("Nová faktúra", systemImage: "square.and.pencil")
                } primaryAction: {
                    model.newInvoice(kind: .invoice)
                }
                .help("Nová faktúra (⌘N)")
            }
        }
        .sheet(item: $model.editingCompany) { c in CompanyEditor(model: model, company: c) }
        .sheet(item: $model.editingClient) { c in ClientEditorSheet(model: model, client: c) }
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showImport) { ImportSheet(model: model) }
        .sheet(item: $model.templateSource) { i in TemplateNameSheet(model: model, source: i) }
        .alert("Nepodarilo sa", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Label(t, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .task { try? await Task.sleep(for: .seconds(3)); model.toast = nil }
            }
        }
        .onAppear { model.openMain = { [openWindow] in openWindow(id: "main") } }
        .onChange(of: model.folder) { _, f in
            // a link (faktury://invoice/<id>) sets the folder and the document together: keep that document
            if case .invoice(let id)? = model.selection, model.list(f ?? .all).contains(where: { $0.id == id }) { return }
            model.selection = nil; selectDefault()
        }
    }

    @ViewBuilder var middle: some View {
        switch model.folder ?? .all {
        case .clients: ClientList(model: model, query: query)
        case .templates: TemplateList(model: model)
        case .overview: OverviewList(model: model)
        case let f: InvoiceList(model: model, folder: f, items: filter(model.list(f)))
        }
    }

    @ViewBuilder var detail: some View {
        switch model.selection {
        case .invoice(let id):
            if let i = model.invoices.first(where: { $0.id == id }), let c = model.company(i.companyId) {
                if i.isDraft { InvoiceEditor(model: model, draft: i, company: c).id(i.id) } else { InvoiceDetail(model: model, inv: i, company: c).id(i.id) }
            } else { empty }
        case .client(let id):
            if let c = model.clients.first(where: { $0.id == id }) { ClientDetail(model: model, client: c).id(c.id) } else { empty }
        case .company(let id):
            if let c = model.company(id) { OverviewDetail(model: model, company: c) } else { empty }
        case .template(let id):
            if let t = model.templates.first(where: { $0.id == id }) { TemplateDetail(model: model, template: t).id(t.id) } else { empty }
        case nil:
            if model.folder == .overview { OverviewDetail(model: model, company: nil) } else { empty }
        }
    }

    var empty: some View {
        ContentUnavailableView("Vyber doklad", systemImage: "doc.text", description: Text("Vľavo vyber faktúru, alebo vytvor novú (⌘N)."))
    }

    func filter(_ items: [Invoice]) -> [Invoice] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { ($0.number ?? "").contains(q) || $0.client.name.localizedCaseInsensitiveContains(q) || $0.client.ico.contains(q)
            || $0.items.contains { $0.description.localizedCaseInsensitiveContains(q) } || $0.note.localizedCaseInsensitiveContains(q) }
    }

    func selectDefault() {
        guard model.selection == nil else { return }
        switch model.folder ?? .all {
        case .clients: model.selection = model.clients.first.map { .client($0.id) }
        case .templates: model.selection = model.templates.first.map { .template($0.id) }
        case .overview: model.selection = nil
        case let f: model.selection = model.list(f).first.map { .invoice($0.id) }
        }
    }
}

/// First start: no subject yet.
struct Welcome: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ContentUnavailableView {
            Label("Vitaj vo Faktúrach", systemImage: "doc.text.fill")
        } description: {
            Text("Najprv založ svoj subjekt – firmu alebo živnosť, za ktorú vystavuješ faktúry. Každý má vlastné údaje, IBAN, DPH a číselný rad.")
        } actions: {
            Button("Založiť subjekt") { model.editCompany(Company()) }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.folder) {
            Section {
                row("Všetky doklady", "tray.full", .blue, .all, count: nil)
                row("Koncepty", "pencil.and.list.clipboard", .gray, .drafts, count: model.list(.drafts).count)
                row("Neuhradené", "clock", .orange, .unpaid, count: model.list(.unpaid).count)
                row("Po splatnosti", "exclamationmark.circle", .red, .overdue, count: model.list(.overdue).count)
                row("Uhradené", "checkmark.circle", .green, .paid, count: nil)
            }
            Section("Subjekty") {
                ForEach(model.companies) { c in
                    Label { Text(c.shortName).lineLimit(1) } icon: { CompanyMark(company: c, size: 18) }
                        .badge(model.list(.company(c.id)).filter { $0.balanceCents > 0 }.count)
                        .tag(Folder.company(c.id))
                        .contextMenu {
                            Button("Upraviť subjekt…") { model.editCompany(c) }
                            Button("Nová faktúra") { model.newInvoice(kind: .invoice, companyId: c.id) }
                            Button("Nová zálohová faktúra") { model.newInvoice(kind: .proforma, companyId: c.id) }
                        }
                }
                Button { model.editCompany(Company()) } label: { Label("Pridať subjekt", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Section {
                row("Šablóny", "doc.on.doc", .purple, .templates, count: nil)
                row("Odberatelia", "person.2", .teal, .clients, count: nil)
                row("Prehľad príjmov", "chart.bar.xaxis", .green, .overview, count: nil)
            }
        }
        .listStyle(.sidebar)
    }

    func row(_ title: String, _ symbol: String, _ tint: Color, _ f: Folder, count: Int?) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .badge(count ?? 0)
            .tag(f)
    }
}

// MARK: Invoice list

struct InvoiceList: View {
    @ObservedObject var model: AppModel
    let folder: Folder
    let items: [Invoice]

    var title: String {
        switch folder {
        case .drafts: "Koncepty"
        case .unpaid: "Neuhradené"
        case .overdue: "Po splatnosti"
        case .paid: "Uhradené"
        case .company(let id): model.company(id)?.shortName ?? "Subjekt"
        default: "Všetky doklady"
        }
    }

    var groups: [(String, [Invoice])] {
        var order: [String] = [], g: [String: [Invoice]] = [:]
        for i in items {
            let k = i.isDraft ? "Koncepty" : Fmt.month(String(i.issueDate.prefix(7)))
            if g[k] == nil { order.append(k) }
            g[k, default: []].append(i)
        }
        return order.map { ($0, g[$0]!) }
    }

    var open: Int { items.reduce(0) { $0 + $1.balanceCents } }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(folder == .overdue ? "Nič po splatnosti" : "Žiadne doklady", systemImage: folder == .overdue ? "checkmark.seal" : "doc.text")
                } description: {
                    Text(folder == .drafts ? "Rozpracované faktúry sa zobrazia tu." : "Novú faktúru vytvoríš cez ⌘N.")
                } actions: {
                    if folder != .overdue && folder != .unpaid && folder != .paid { Button("Nová faktúra") { model.newInvoice(kind: .invoice) } }
                }
            } else {
                List(selection: $model.selection) {
                    ForEach(groups, id: \.0) { title, list in
                        Section(title) { ForEach(list) { i in InvoiceRow(i: i, company: model.company(i.companyId), showCompany: showCompany).tag(Pick.invoice(i.id)) } }
                    }
                }
                // a fresh list per folder: macOS otherwise reuses row heights measured in another folder and clips rows
                .id(folder)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(open > 0 ? "\(items.count) dokladov · neuhradené \(Money.string(open))" : "\(items.count) dokladov")
    }

    var showCompany: Bool {
        if case .company = folder { return false }
        return model.companies.count > 1
    }
}

struct InvoiceRow: View {
    let i: Invoice
    let company: Company?
    var showCompany = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showCompany { CompanyMark(company: company, size: 22).padding(.top, 1) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(i.client.name.isEmpty ? "Bez odberateľa" : i.client.name).font(.body.weight(.medium)).lineLimit(1)
                        .foregroundStyle(i.client.name.isEmpty ? .secondary : .primary)
                    Spacer(minLength: 6)
                    Text(Money.string(i.isDraft ? i.totals.totalCents : i.totalCents, currency: i.currency)).font(.body.weight(.medium)).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(i.number.map { "\(i.kind == .invoice ? "" : i.kind.title + " ")\($0)" } ?? i.kind.title).monospacedDigit()
                    Text("·")
                    Text(i.isDraft ? "upravené \(Fmt.day(String(i.updatedAt.prefix(10))))" : Fmt.day(i.issueDate))
                    Spacer(minLength: 4)
                    StatusPill(i: i)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let first = i.items.first?.description, !first.isEmpty {
                    Text(i.items.count > 1 ? "\(first) a ďalšie (\(i.items.count))" : first).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
