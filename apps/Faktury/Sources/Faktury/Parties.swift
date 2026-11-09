import FakturyCore
import SwiftUI

// MARK: Clients

struct ClientList: View {
    @ObservedObject var model: AppModel
    let query: String

    var items: [Client] { query.isEmpty ? model.clients : model.store.searchClients(query, limit: 500) }

    var body: some View {
        Group {
            if model.clients.isEmpty {
                ContentUnavailableView {
                    Label("Zatiaľ žiadni odberatelia", systemImage: "person.2")
                } description: {
                    Text("Pridaj ich tu alebo priamo pri faktúre – stačí IČO, zvyšok sa doplní z registra.")
                } actions: { Button("Nový odberateľ") { model.editClient(Client()) } }
            } else {
                List(selection: $model.selection) {
                    ForEach(items) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.body.weight(.medium)).lineLimit(1)
                            Text([c.ico.isEmpty ? nil : "IČO \(c.ico)", c.city.isEmpty ? nil : c.city, c.email.isEmpty ? nil : c.email].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 3)
                        .tag(Pick.client(c.id))
                    }
                }
            }
        }
        .navigationTitle("Odberatelia")
        .navigationSubtitle("\(model.clients.count)")
        .toolbar {
            ToolbarItem { Button { model.editClient(Client()) } label: { Label("Nový odberateľ", systemImage: "person.badge.plus") } }
        }
    }
}

struct ClientDetail: View {
    @ObservedObject var model: AppModel
    let client: Client

    var docs: [Invoice] { model.invoices.filter { $0.clientId == client.id } }

    var body: some View {
        Page {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(client.name).font(.title2.weight(.semibold))
                    Text(client.addressLines.joined(separator: ", ")).foregroundStyle(.secondary)
                    Text([client.ico.isEmpty ? nil : "IČO \(client.ico)", client.dic.isEmpty ? nil : "DIČ \(client.dic)", client.icDph.isEmpty ? nil : "IČ DPH \(client.icDph)"]
                        .compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    if !client.email.isEmpty { Label(client.email, systemImage: "envelope").font(.callout) }
                    else { Label("Chýba e-mail na faktúry", systemImage: "envelope.badge").font(.callout).foregroundStyle(.orange) }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Button("Upraviť…") { model.editClient(client) }
                    Button("Nová faktúra") { model.newInvoice(kind: .invoice, client: client) }.buttonStyle(.borderedProminent)
                }
            }
            StatGrid {
                StatTile("Fakturované", Money.string(docs.filter { $0.status == .issued && $0.kind != .proforma }.reduce(0) { $0 + $1.totalCents }),
                         detail: "\(docs.filter { !$0.isDraft }.count) dokladov", symbol: "doc.text", tint: .blue)
                StatTile("Neuhradené", Money.string(docs.reduce(0) { $0 + $1.balanceCents }), symbol: "clock", tint: .orange)
            }
            if !docs.isEmpty {
                Card("Doklady", symbol: "doc.on.doc") {
                    ForEach(docs) { i in
                        Button { model.folder = .company(i.companyId); model.selection = .invoice(i.id) } label: {
                            InvoiceRow(i: i, company: model.company(i.companyId), showCompany: model.companies.count > 1).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(client.name)
    }
}

/// Create or edit a client; IČO or EU VAT number fills the rest from the registers.
struct ClientEditorSheet: View {
    @ObservedObject var model: AppModel
    @State var client: Client
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        TextField("IČO", text: $client.ico)
                        Button("Doplniť z registra") { lookup(client.ico) }.disabled(client.ico.filter(\.isNumber).count < 6 || busy)
                    }
                    HStack {
                        TextField("IČ DPH", text: $client.icDph)
                        Button("Overiť vo VIES") { lookup(client.icDph) }.disabled(client.icDph.count < 5 || busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                    if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
                } header: { Text(client.id == 0 ? "Nový odberateľ" : "Odberateľ") } footer: {
                    Text("Slovenské firmy podľa IČO z Registra účtovných závierok (názov, adresa, DIČ), IČ DPH overí VIES. Firmy z EÚ podľa IČ DPH.")
                }
                Section {
                    TextField("Názov / meno", text: $client.name)
                    TextField("DIČ", text: $client.dic)
                    TextField("Ulica a číslo", text: $client.street)
                    HStack { TextField("PSČ", text: $client.zip).frame(maxWidth: 140); TextField("Mesto", text: $client.city) }
                    Picker("Krajina", selection: $client.country) {
                        ForEach(countries, id: \.self) { Text(Country.name($0)).tag($0) }
                    }
                }
                Section("Kontakt") {
                    TextField("E-mail na faktúry", text: $client.email)
                    TextField("Kontaktná osoba", text: $client.contactName)
                    TextField("Telefón", text: $client.phone)
                    TextField("Poznámka", text: $client.note, axis: .vertical)
                }
            }
            .formStyle(.grouped)
            HStack {
                if client.id != 0 { Button("Zmazať", role: .destructive) { confirmDelete = true } }
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uložiť") {
                    model.run { _ = try model.store.save(client) }
                    if model.error == nil { dismiss() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(client.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
        .confirmationDialog("Zmazať odberateľa \(client.name)?", isPresented: $confirmDelete) {
            Button("Zmazať", role: .destructive) { model.run { try model.store.deleteClient(client.id) }; dismiss() }
        }
    }

    var countries: [String] {
        let base = ["SK", "CZ", "AT", "DE", "HU", "PL", "GB", "US", "NL", "FR", "IT", "ES", "CH", "IE", "BE", "SI", "HR", "RO", "BG", "LT", "LV", "EE", "SE", "DK", "FI", "NO", "PT", "GR", "LU", "CY", "MT"]
        return base.contains(client.country) ? base : base + [client.country]
    }

    func lookup(_ q: String) {
        busy = true; message = nil
        Task {
            do {
                if let found = try await CompanyLookup.find(q) {
                    let keep = client
                    client = found
                    client.id = keep.id
                    if !keep.email.isEmpty { client.email = keep.email }
                    client.contactName = keep.contactName; client.phone = keep.phone; client.note = keep.note
                    message = found.source == "vies" ? "Údaje z VIES – skontroluj adresu." : "Doplnené z registra\(found.icDph.isEmpty ? " (nie je platiteľ DPH)" : "")."
                } else { message = "Nič sa nenašlo." }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}

// MARK: Subjects

/// My own subject: a company or a sole trader, with its bank, VAT status and number series.
struct CompanyEditor: View {
    @ObservedObject var model: AppModel
    @State var company: Company
    @Environment(\.dismiss) private var dismiss
    @State private var next: [InvoiceKind: Int] = [:]
    @State private var busy = false
    @State private var message: String?
    @State private var courierAccounts: [String] = []
    let year = Int(Day.today.prefix(4))!

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Typ", selection: $company.legalForm) {
                        Text("Firma").tag(LegalForm.company)
                        Text("Živnosť").tag(LegalForm.soleTrader)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("IČO", text: $company.ico)
                        Button("Doplniť z registra") { lookup() }.disabled(company.ico.filter(\.isNumber).count < 6 || busy)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
                    TextField(company.legalForm == .company ? "Obchodné meno" : "Meno a priezvisko (obchodné meno)", text: $company.name)
                    TextField("Ulica a číslo", text: $company.street)
                    HStack { TextField("PSČ", text: $company.zip).frame(maxWidth: 140); TextField("Mesto", text: $company.city) }
                    TextField("Zápis v registri", text: $company.registry, prompt: Text(company.legalForm.registryPlaceholder), axis: .vertical)
                        .lineLimit(1...3)
                } header: { Text(company.id == 0 ? "Nový subjekt" : company.name) }

                Section {
                    TextField("DIČ", text: $company.dic)
                    Toggle("Platiteľ DPH", isOn: $company.vatPayer)
                    if company.vatPayer { TextField("IČ DPH", text: $company.icDph, prompt: Text("SK…")) }
                } header: { Text("Dane") } footer: {
                    Text(company.vatPayer ? "Faktúry budú s DPH (23 / 19 / 5 %), pre firmy z EÚ s prenesením daňovej povinnosti."
                                          : "Na faktúrach bude „Nie je platiteľ DPH“ a sumy bez DPH.")
                }

                Section("Banka") {
                    HStack {
                        TextField("IBAN", text: $company.iban)
                            .onChange(of: company.iban) { _, v in fillBank(v) }
                        if !company.iban.isEmpty {
                            Image(systemName: Validation.iban(company.iban) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(Validation.iban(company.iban) ? .green : .red)
                        }
                    }
                    TextField("SWIFT / BIC", text: $company.swift)
                    TextField("Banka", text: $company.bankName)
                }

                Section {
                    TextField("E-mail", text: $company.email)
                    TextField("Telefón", text: $company.phone)
                    TextField("Web", text: $company.web)
                    Picker("Posielať faktúry z (Courier)", selection: $company.senderEmail) {
                        Text("Podľa e-mailu vyššie").tag("")
                        ForEach(accountsList, id: \.self) { Text($0).tag($0) }
                    }
                } header: { Text("Kontakt") }

                Section("Faktúry") {
                    Stepper("Splatnosť \(company.dueDays) dní", value: $company.dueDays, in: 0...120)
                    TextField("Vystavil", text: $company.issuedBy, prompt: Text("Meno (tlačí sa v pätičke)"))
                    TextField("Text v pätičke", text: $company.footerNote, prompt: Text("napr. Ďakujeme za spoluprácu"), axis: .vertical)
                    LabeledContent("Farba") {
                        HStack(spacing: 6) {
                            ForEach(Palette.names, id: \.self) { n in
                                Circle().fill(Palette.color(n).gradient).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(.primary.opacity(company.color == n ? 0.8 : 0), lineWidth: 2))
                                    .onTapGesture { company.color = n }
                                    .help(Palette.label(n))
                            }
                        }
                    }
                    LabeledContent("Logo (nepovinné)") {
                        HStack {
                            if !company.logoPath.isEmpty { Text(URL(fileURLWithPath: company.logoPath).lastPathComponent).foregroundStyle(.secondary); Button("Odstrániť") { company.logoPath = "" } }
                            Button("Vybrať…") { pickLogo() }
                        }
                    }
                }

                Section {
                    series(.invoice, "Faktúry", $company.invoicePattern)
                    series(.proforma, "Zálohové", $company.proformaPattern)
                    series(.creditNote, "Dobropisy", $company.creditPattern)
                } header: { Text("Číselné rady \(String(year))") } footer: {
                    Text("{YYYY} rok, {YY} rok dvojmiestne, {MM} mesiac, {NNNN} poradové číslo (počet N = počet číslic). Ďalšie číslo nastav tak, aby rad nadviazal na doterajšie faktúry. Číslo sa pridelí až pri vystavení.")
                }
            }
            .formStyle(.grouped)
            HStack {
                if company.id != 0 {
                    Toggle("Archivovať", isOn: $company.archived).toggleStyle(.checkbox).help("Skryje subjekt; doklady ostanú")
                }
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(company.id == 0 ? "Založiť subjekt" : "Uložiť") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(company.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 600, height: 760)
        .onAppear {
            for k in InvoiceKind.allCases { next[k] = company.id == 0 ? 1 : model.store.nextNumber(companyId: company.id, kind: k, year: year) }
        }
        .task {
            let list = await Task.detached { CourierBridge.accounts() }.value
            courierAccounts = list
        }
    }

    var accountsList: [String] {
        var l = courierAccounts
        if !company.senderEmail.isEmpty && !l.contains(company.senderEmail) { l.append(company.senderEmail) }
        return l
    }

    func series(_ k: InvoiceKind, _ title: String, _ pattern: Binding<String>) -> some View {
        let n = Binding<Int>(get: { next[k] ?? 1 }, set: { next[k] = max(1, $0) })
        return HStack {
            Text(title).frame(width: 80, alignment: .leading)
            TextField("Vzor", text: pattern).frame(width: 130).labelsHidden()
            Text("ďalšie").foregroundStyle(.secondary)
            TextField("Ďalšie", value: n, format: .number.grouping(.never)).frame(width: 60).labelsHidden()
            Stepper("", value: n, in: 1...999_999).labelsHidden()
            Spacer()
            Text(Store.format(pattern.wrappedValue, year: year, month: Calendar.current.component(.month, from: Date()), n: next[k] ?? 1))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }

    func save() {
        model.run {
            let saved = try model.store.save(company)
            for k in InvoiceKind.allCases {
                let want = next[k] ?? 1
                if want != model.store.nextNumber(companyId: saved.id, kind: k, year: year) { try model.store.setNextNumber(companyId: saved.id, kind: k, year: year, want) }
            }
            if company.id == 0 { model.folder = .company(saved.id) }
        }
        if model.error == nil { dismiss() }
    }

    func lookup() {
        busy = true; message = nil
        Task {
            do {
                if let c = try await CompanyLookup.byICO(company.ico) {
                    company.name = c.name; company.street = c.street; company.city = c.city; company.zip = c.zip; company.dic = c.dic
                    if !c.icDph.isEmpty { company.icDph = c.icDph; company.vatPayer = true }
                    message = "Doplnené z registra\(c.icDph.isEmpty ? "; IČ DPH sa vo VIES nenašlo" : ", platiteľ DPH (VIES)")."
                } else {
                    message = company.legalForm == .soleTrader ? "Živnosť sa v registri závierok nenašla – doplň údaje ručne." : "V registri sa nič nenašlo."
                }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    /// SWIFT and bank name from a Slovak IBAN's bank code.
    func fillBank(_ iban: String) {
        let t = iban.replacingOccurrences(of: " ", with: "").uppercased()
        guard t.hasPrefix("SK"), t.count >= 8 else { return }
        let banks: [String: (String, String)] = [
            "0200": ("SUBASKBX", "Všeobecná úverová banka"), "0900": ("GIBASKBX", "Slovenská sporiteľňa"), "1100": ("TATRSKBX", "Tatra banka"),
            "1111": ("UNCRSKBX", "UniCredit Bank"), "3100": ("LUBASKBX", "365.bank"), "5200": ("OTPVSKBX", "OTP Banka"), "5600": ("KOMASK2X", "Prima banka"),
            "6500": ("POBNSKBA", "Poštová banka"), "7500": ("CEKOSKBX", "ČSOB"), "8360": ("BREXSKBX", "mBank"), "8330": ("FIOZSKBA", "Fio banka"),
            "3000": ("SLZBSKBA", "Slovenská záručná a rozvojová banka"), "8180": ("SPSRSKBA", "Štátna pokladnica"), "1300": ("TATRSKBX", "Tatra banka"),
        ]
        let code = String(t.dropFirst(4).prefix(4))
        if let b = banks[code] {
            if company.swift.isEmpty { company.swift = b.0 }
            if company.bankName.isEmpty { company.bankName = b.1 }
        }
    }

    func pickLogo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .pdf, .svg]
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        let dir = model.store.dir.appendingPathComponent("logos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: dst); company.logoPath = dst.path } catch { message = error.localizedDescription }
    }
}
