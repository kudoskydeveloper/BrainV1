import FakturyCore
import SwiftUI

/// A draft: the form on the left, the invoice exactly as it will print on the right. Saves as you type.
struct InvoiceEditor: View {
    @ObservedObject var model: AppModel
    @State var draft: Invoice
    let company: Company
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmIssue = false
    @State private var confirmDelete = false
    @State private var showPreview = true
    @Environment(\.snapshot) private var snapshot

    init(model: AppModel, draft: Invoice, company: Company) {
        self.model = model; self._draft = State(initialValue: draft); self.company = company
    }

    var co: Company { model.company(draft.companyId) ?? company }
    var check: Store.Check { model.store.check(draft) }
    var number: String { model.store.previewNumber(draft) ?? "" }

    var body: some View {
        // no minimum widths here: they made the split view push the sidebar off the window. The preview shows when there is room.
        GeometryReader { g in
            let side = showPreview && g.size.width >= 780
            HStack(spacing: 0) {
                form.frame(width: side ? min(620, g.size.width * 0.56) : g.size.width)
                if side {
                    Divider()
                    PreviewPane(inv: draft, company: co)
                }
            }
        }
        .navigationTitle(draft.kind == .creditNote ? "Dobropis – koncept" : "\(draft.kind.title) – koncept")
        .navigationSubtitle("\(co.shortName) · dostane číslo \(number)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showPreview.toggle() } label: { Label("Náhľad", systemImage: showPreview ? "sidebar.trailing" : "doc.richtext") }
                    .help(showPreview ? "Skryť náhľad" : "Zobraziť náhľad")
                Button { save(now: true); confirmIssue = true } label: { Label("Vystaviť", systemImage: "checkmark.seal") }
                    .disabled(!check.ok)
                    .help(check.ok ? "Vystaviť (pridelí číslo \(number))" : "Najprv doplň, čo chýba")
            }
        }
        .confirmationDialog("Vystaviť \(draft.kind.title.lowercased()) \(number)?", isPresented: $confirmIssue, titleVisibility: .visible) {
            Button("Vystaviť \(number)") { issue() }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("\(draft.client.name) · \(Money.string(draft.totals.totalCents, currency: draft.currency)) · splatnosť \(Day.sk(draft.dueDate)).\nVystavený doklad sa už nedá meniť, oprava len dobropisom.")
        }
        .confirmationDialog("Zmazať koncept?", isPresented: $confirmDelete) {
            Button("Zmazať koncept", role: .destructive) { model.run { try model.store.deleteDraft(draft.id) }; model.selection = nil }
        }
        .onChange(of: draft) { _, _ in save() }
        .onDisappear { save(now: true) }
    }

    func save(now: Bool = false) {
        saveTask?.cancel()
        let d = draft
        guard !snapshot else { return }
        if now { persist(d); return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persist(d)
        }
    }

    func persist(_ d: Invoice) {
        guard model.store.invoice(d.id)?.isDraft == true else { return }
        do {
            _ = try model.store.saveDraft(d)
            if let i = model.invoices.firstIndex(where: { $0.id == d.id }) { var x = d; x.updatedAt = Day.now; model.invoices[i] = x }
        } catch { model.error = error.localizedDescription }
    }

    func issue() {
        persist(draft)
        model.run {
            let i = try model.store.issue(draft.id)
            model.selection = .invoice(i.id)
            model.toast = "Vystavená \(i.kind.title.lowercased()) \(i.number ?? "")."
        }
    }

    // MARK: Form

    var form: some View {
        Form {
            Section {
                if model.companies.count > 1 && draft.kind != .creditNote {
                    Picker("Subjekt", selection: $draft.companyId) {
                        ForEach(model.companies) { c in Text(c.name).tag(c.id) }
                    }
                    .onChange(of: draft.companyId) { _, id in
                        guard let c = model.company(id) else { return }
                        model.store.applyClientDefaults(&draft, company: c)
                        if !c.vatPayer { draft.vatMode = .nonPayer } else if draft.vatMode == .nonPayer { draft.vatMode = .standard }
                        draft.dueDate = Day.adding(c.dueDays, to: draft.issueDate)
                    }
                }
                if draft.kind != .creditNote {
                    Picker("Doklad", selection: $draft.kind) {
                        Text("Faktúra").tag(InvoiceKind.invoice)
                        Text("Zálohová faktúra").tag(InvoiceKind.proforma)
                    }
                    .pickerStyle(.segmented)
                } else {
                    LabeledContent("Dobropis k faktúre", value: draft.creditsNumber ?? "")
                    TextField("Dôvod opravy", text: $draft.creditReason, prompt: Text("napr. zľava po dohode, vrátenie, chyba v sume"), axis: .vertical)
                }
            }

            Section("Odberateľ") {
                ClientPicker(model: model, draft: $draft, company: co)
            }

            Section("Dátumy") {
                DatePicker("Vystavená", selection: $draft.issueDate.date, displayedComponents: .date)
                    .onChange(of: draft.issueDate) { old, new in
                        if draft.deliveryDate == old { draft.deliveryDate = new }
                        draft.dueDate = Day.adding(Day.diff(old, draft.dueDate), to: new)
                    }
                DatePicker(draft.kind == .creditNote ? "Dátum opravy" : "Dodanie", selection: $draft.deliveryDate.date, displayedComponents: .date)
                HStack {
                    DatePicker("Splatnosť", selection: $draft.dueDate.date, displayedComponents: .date)
                    Spacer()
                    ForEach([7, 14, 30], id: \.self) { d in
                        Button("\(d) dní") { draft.dueDate = Day.adding(d, to: draft.issueDate) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(Day.diff(draft.issueDate, draft.dueDate) == d ? .accentColor : .secondary)
                    }
                }
            }

            Section {
                ItemsEditor(items: $draft.items, vat: draft.vatMode.chargesVat, credit: draft.kind == .creditNote)
            } header: {
                Text("Položky")
            } footer: {
                TotalsFooter(inv: draft)
            }

            Section("Platba a DPH") {
                if co.vatPayer {
                    Picker("DPH", selection: $draft.vatMode) {
                        Text("S DPH").tag(VatMode.standard)
                        Text("Prenesenie daňovej povinnosti").tag(VatMode.reverseCharge)
                    }
                } else {
                    LabeledContent("DPH", value: "Neplatiteľ DPH")
                }
                Picker("Forma úhrady", selection: $draft.paymentMethod) {
                    ForEach(PaymentMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Variabilný symbol", text: $draft.variableSymbol, prompt: Text(String(number.filter(\.isNumber).suffix(10))))
            }

            Section("Poznámky") {
                TextField("Poznámka na faktúre", text: $draft.note, axis: .vertical).lineLimit(2...5)
                TextField("Interná poznámka (netlačí sa)", text: $draft.internalNote, axis: .vertical).lineLimit(1...4)
            }

            Section {
                if !check.errors.isEmpty {
                    ForEach(check.errors, id: \.self) { Label($0, systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                }
                ForEach(check.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                HStack {
                    Button("Zmazať koncept", role: .destructive) { confirmDelete = true }
                    Button("Uložiť ako šablónu…") { save(now: true); model.templateSource = draft }
                    Spacer()
                    Button { save(now: true); confirmIssue = true } label: { Label("Vystaviť \(number)", systemImage: "checkmark.seal.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!check.ok)
                }
            } header: {
                Text(check.ok ? "Pripravené na vystavenie" : "Pred vystavením doplň")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}

/// Sum under the items: base, VAT, total.
struct TotalsFooter: View {
    let inv: Invoice
    var body: some View {
        let t = inv.totals
        HStack(alignment: .firstTextBaseline) {
            if inv.vatMode.chargesVat {
                Text("Základ \(Money.string(t.subtotalCents)) · DPH \(Money.string(t.vatCents))").foregroundStyle(.secondary)
            }
            Spacer()
            Text(inv.kind == .creditNote ? "Dobropis" : "Spolu").foregroundStyle(.secondary)
            Text(Money.string(t.totalCents, currency: inv.currency)).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .padding(.top, 4)
    }
}

struct ItemsEditor: View {
    @Binding var items: [Item]
    let vat: Bool
    let credit: Bool

    var body: some View {
        ForEach($items) { $it in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Popis", text: $it.description, prompt: Text("Čo fakturuješ"), axis: .vertical).labelsHidden()
                    Button { items.removeAll { $0.id == it.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Odstrániť položku").disabled(items.count == 1)
                }
                HStack(spacing: 8) {
                    NumberField(title: "Množstvo", value: $it.quantity).frame(width: 70)
                    TextField("MJ", text: $it.unit).frame(width: 64)
                        .textInputSuggestions { ForEach(Units.common, id: \.self) { Text($0).textInputCompletion($0) } }
                    Text("×").foregroundStyle(.secondary)
                    MoneyField(title: "Cena", cents: $it.unitPriceCents).frame(width: 96)
                    Text("€").foregroundStyle(.secondary)
                    if vat {
                        Picker("DPH", selection: $it.vatRate) {
                            ForEach([23.0, 19.0, 5.0, 0.0], id: \.self) { Text(Money.rate($0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 76)
                    }
                    Spacer(minLength: 4)
                    Text(Money.string(it.netCents)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
        Button {
            var n = Item(quantity: credit ? -1 : 1, unit: items.last?.unit ?? "ks", vatRate: vat ? (items.last?.vatRate ?? 23) : 0)
            n.description = ""
            items.append(n)
        } label: { Label("Pridať položku", systemImage: "plus.circle.fill") }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
    }
}

/// Search local clients, or look a company up in the register by IČO / VAT number.
struct ClientPicker: View {
    @ObservedObject var model: AppModel
    @Binding var draft: Invoice
    let company: Company
    @State private var query = ""
    @State private var searching = false
    @State private var lookupError: String?
    @State private var changing = false

    var body: some View {
        if !draft.client.name.isEmpty && !changing {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.client.name).font(.body.weight(.semibold))
                    Text(draft.client.addressLines.joined(separator: ", ")).foregroundStyle(.secondary)
                    Text([draft.client.ico.isEmpty ? nil : "IČO \(draft.client.ico)", draft.client.dic.isEmpty ? nil : "DIČ \(draft.client.dic)",
                          draft.client.icDph.isEmpty ? nil : "IČ DPH \(draft.client.icDph)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if draft.client.email.isEmpty { Label("Bez e-mailu na faktúry", systemImage: "envelope.badge").font(.caption).foregroundStyle(.orange) }
                    else { Label(draft.client.email, systemImage: "envelope").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Zmeniť") { changing = true; query = "" }
                    if let id = draft.clientId, let c = model.store.client(id) { Button("Upraviť") { model.editClient(c) } }
                }
                .controlSize(.small)
            }
            .onChange(of: model.clients) { _, list in
                if let id = draft.clientId, let c = list.first(where: { $0.id == id }), c != draft.client { draft.client = c }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Odberateľ", text: $query, prompt: Text("Názov, IČO alebo IČ DPH (napr. CZ12345678)"))
                        .onSubmit { if hits.isEmpty { lookup() } }
                    if searching { ProgressView().controlSize(.small) }
                    else if looksLikeID { Button("Dohľadať v registri") { lookup() } }
                    if changing { Button("Zrušiť") { changing = false } }
                }
                if let e = lookupError { Text(e).font(.caption).foregroundStyle(.red) }
                ForEach(hits) { c in
                    Button { pick(c) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.name)
                                Text([c.ico.isEmpty ? nil : "IČO \(c.ico)", c.city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Button { var c = Client(); c.name = looksLikeID ? "" : query; model.editClient(c) } label: { Label("Nový odberateľ ručne…", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.callout)
            }
            .onChange(of: model.clients) { old, new in
                // a client created in the sheet is picked right away
                if let added = new.first(where: { c in !old.contains { $0.id == c.id } }) { pick(added) }
            }
        }
    }

    var hits: [Client] { query.isEmpty ? Array(model.clients.prefix(6)) : model.store.searchClients(query, limit: 6) }
    var looksLikeID: Bool {
        let t = query.replacingOccurrences(of: " ", with: "")
        return (t.count >= 6 && t.allSatisfy(\.isNumber)) || (t.count > 4 && t.prefix(2).allSatisfy(\.isLetter) && t.dropFirst(2).allSatisfy(\.isNumber))
    }

    func pick(_ c: Client) {
        draft.client = c
        draft.clientId = c.id
        model.store.applyClientDefaults(&draft, company: company)
        changing = false
        query = ""
    }

    func lookup() {
        let q = query
        searching = true; lookupError = nil
        Task {
            do {
                if let c = try await CompanyLookup.find(q) {
                    if let existing = model.clients.first(where: { !c.ico.isEmpty && $0.ico == c.ico }) { pick(existing) }
                    else { model.editClient(c) }
                } else { lookupError = "V registri sa nič nenašlo. Zadaj odberateľa ručne." }
            } catch { lookupError = error.localizedDescription }
            searching = false
        }
    }
}

/// The printed pages, scaled to the pane width.
struct PreviewPane: View {
    let inv: Invoice
    let company: Company
    var body: some View {
        GeometryReader { g in
            let scale = min(1.4, max(0.3, (g.size.width - 40) / A4.size.width))
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(Array(InvoicePDF.views(inv, company: company).enumerated()), id: \.offset) { _, page in
                        page
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: A4.size.width * scale, height: A4.size.height * scale, alignment: .topLeading)
                            .clipShape(.rect(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
