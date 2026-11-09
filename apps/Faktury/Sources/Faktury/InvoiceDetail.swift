import FakturyCore
import PDFKit
import SwiftUI

/// An issued document: status and actions on top, the stored PDF below (exactly the file that goes out).
struct InvoiceDetail: View {
    @ObservedObject var model: AppModel
    let inv: Invoice
    let company: Company
    @State private var paying = false
    @State private var crediting = false
    @State private var internalNote = ""
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    actions
                    if inv.kind != .creditNote && inv.status == .issued { payments }
                    related
                    Card("Interná poznámka", symbol: "note.text") {
                        TextField("Netlačí sa na faktúru", text: $internalNote, axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(1...4)
                            .onSubmit { saveNote() }
                            .onChange(of: internalNote) { _, _ in }
                        if internalNote != inv.internalNote { Button("Uložiť") { saveNote() }.controlSize(.small) }
                    }
                }
                .padding(20)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            if let p = inv.pdfPath, FileManager.default.fileExists(atPath: p) {
                PDFPreview(url: URL(fileURLWithPath: p))
            } else {
                PreviewPane(inv: inv, company: inv.supplier ?? company)
            }
        }
        .navigationTitle("\(inv.kind.title) \(inv.number ?? "")")
        .navigationSubtitle("\(inv.client.name) · \(Money.string(inv.totalCents, currency: inv.currency))")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let p = inv.pdfPath {
                    ShareLink(item: URL(fileURLWithPath: p)) { Label("Zdieľať PDF", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .onAppear { internalNote = inv.internalNote }
        .sheet(isPresented: $paying) { PaymentSheet(model: model, inv: inv) }
        .sheet(isPresented: $crediting) { CreditSheet(model: model, inv: inv) }
        .confirmationDialog("Zmazať \(inv.kind.title.lowercased()) \(inv.number ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Zmazať", role: .destructive) { model.run { try model.store.deleteDocument(inv.id) }; model.selection = nil }
        } message: {
            Text(inv.imported ? "Importovaný záznam a jeho kópia PDF sa odstránia (originál ostane v Import › Hotové)."
                              : "Doklad a jeho PDF sa odstránia a číselný rad sa vráti na \(inv.number ?? ""). V audit logu ostane záznam.")
        }
        .confirmationDialog("Zrušiť zálohovú faktúru \(inv.number ?? "")?", isPresented: $confirmCancel) {
            Button("Zrušiť zálohovú faktúru", role: .destructive) { model.run { try model.store.cancelProforma(inv.id) } }
        } message: { Text("Číslo ostane použité, doklad sa označí ako zrušený.") }
    }

    func saveNote() { model.run { try model.store.setNotes(inv.id, internalNote: internalNote) } }

    var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    CompanyMark(company: company, size: 20)
                    Text(company.shortName).foregroundStyle(.secondary)
                    StatusPill(i: inv)
                    if inv.imported { Pill(text: "Importovaná", color: .teal, symbol: "tray.and.arrow.down") }
                    else if inv.sentAt != nil { Pill(text: "Odoslaná", color: .blue, symbol: "paperplane") }
                }
                Text(inv.client.name).font(.title2.weight(.semibold))
                Text("\(inv.kind.title) \(inv.number ?? "") · vystavená \(Day.sk(inv.issueDate)) · splatná \(Day.sk(inv.dueDate))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.string(inv.totalCents, currency: inv.currency)).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                if inv.balanceCents > 0 && inv.balanceCents != inv.totalCents {
                    Text("zostáva \(Money.string(inv.balanceCents))").foregroundStyle(.orange).monospacedDigit()
                }
                if inv.vatMode.chargesVat { Text("z toho DPH \(Money.string(inv.vatCents))").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    var actions: some View {
        HStack(spacing: 8) {
            if inv.status == .issued {
                Button { model.sendViaCourier(inv) } label: {
                    if model.sending.contains(inv.id) { ProgressView().controlSize(.small) } else { Label("Poslať cez Courier", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sending.contains(inv.id))
                .help(inv.client.email.isEmpty ? "Odberateľ nemá e-mail – doplň ho v Odberateľoch" : "Koncept e-mailu s PDF na \(inv.client.email)")
                if inv.sentAt == nil {
                    Button("Označiť ako odoslanú") { model.run { try model.store.markSent(inv.id) } }
                }
                if inv.kind != .creditNote && inv.balanceCents > 0 {
                    Button { paying = true } label: { Label("Uhradená…", systemImage: "checkmark.circle") }
                }
            }
            Spacer()
            Menu {
                if inv.kind == .invoice && inv.status == .issued { Button("Vystaviť dobropis…") { crediting = true } }
                if inv.kind == .proforma && inv.status == .issued {
                    Button("Vytvoriť faktúru zo zálohovej") { model.run { let d = try model.store.invoiceFromProforma(inv.id); model.reload(); model.selection = .invoice(d.id) } }
                    Button("Zrušiť zálohovú faktúru…", role: .destructive) { confirmCancel = true }
                }
                Button("Uložiť ako šablónu…") { model.templateSource = inv }
                Button("Duplikovať ako nový koncept") { model.run { let d = try model.store.duplicate(inv.id); model.reload(); model.selection = .invoice(d.id) } }
                Divider()
                if let p = inv.pdfPath {
                    Button("Otvoriť PDF") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                    Button("Ukázať vo Finderi") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                }
                if let id = inv.clientId, let c = model.store.client(id) { Button("Odberateľ…") { model.editClient(c) } }
                Divider()
                if let why = model.store.deleteBlocker(inv) {
                    Button("Zmazať doklad") {}.disabled(true).help(why)
                    Text(why)
                } else {
                    Button("Zmazať doklad…", role: .destructive) { confirmDelete = true }
                }
            } label: { Label("Ďalšie", systemImage: "ellipsis.circle") }
            .fixedSize()
        }
    }

    @ViewBuilder var payments: some View {
        let list = model.store.payments(inv.id)
        if !list.isEmpty {
            Card("Úhrady", symbol: "banknote", tint: .green) {
                ForEach(list) { p in
                    HStack {
                        Text(Day.sk(p.date)).monospacedDigit()
                        if !p.note.isEmpty { Text(p.note).foregroundStyle(.secondary) }
                        Spacer()
                        Text(Money.string(p.amountCents)).monospacedDigit()
                        Button { model.run { try model.store.deletePayment(p.id) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Zmazať úhradu")
                    }
                }
            }
        }
    }

    @ViewBuilder var related: some View {
        let credits = model.invoices.filter { $0.creditsInvoiceId == inv.id }
        if inv.kind == .creditNote, let id = inv.creditsInvoiceId {
            Notice(symbol: "arrow.uturn.backward.circle.fill", text: "Dobropis k faktúre \(inv.creditsNumber ?? ""). Dôvod: \(inv.creditReason)", tint: .purple)
                .onTapGesture { model.selection = .invoice(id) }
        }
        ForEach(credits) { c in
            Notice(symbol: "arrow.uturn.backward.circle.fill",
                   text: "\(c.isDraft ? "Rozpracovaný dobropis" : "Dobropis \(c.number ?? "")") na \(Money.string(c.totalCents)). \(c.creditReason)", tint: .purple)
                .onTapGesture { model.selection = .invoice(c.id) }
        }
        if inv.isOverdue && inv.status == .issued {
            Notice(symbol: "exclamationmark.triangle.fill", text: "Po splatnosti \(Day.diff(inv.dueDate, Day.today)) dní, zostáva \(Money.string(inv.balanceCents)).", tint: .red)
        }
        if inv.sentAt == nil && inv.status == .issued && inv.issueDate < Day.today {
            Notice(symbol: "paperplane.circle.fill", text: "Faktúra ešte nebola odoslaná odberateľovi (vystavená \(Day.sk(inv.issueDate))).")
        }
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .underPageBackgroundColor
        v.document = PDFDocument(url: url)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

struct PaymentSheet: View {
    @ObservedObject var model: AppModel
    let inv: Invoice
    @Environment(\.dismiss) private var dismiss
    @State private var cents = 0
    @State private var date = Day.today
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Úhrada faktúry \(inv.number ?? "")").font(.title3.weight(.semibold))
            Form {
                LabeledContent("Suma") { HStack { MoneyField(title: "Suma", cents: $cents).frame(width: 140); Text("€") } }
                DatePicker("Dátum úhrady", selection: $date.date, displayedComponents: .date)
                TextField("Poznámka", text: $note)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zapísať úhradu") {
                    model.run { try model.store.addPayment(inv.id, amountCents: cents, date: date, note: note) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(cents == 0)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { cents = inv.balanceCents }
    }
}

struct CreditSheet: View {
    @ObservedObject var model: AppModel
    let inv: Invoice
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dobropis k faktúre \(inv.number ?? "")").font(.title3.weight(.semibold))
            Text("Vznikne koncept dobropisu s rovnakými položkami so zápornými množstvami. Pre čiastočný dobropis ich v koncepte uprav.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Dôvod opravy", text: $reason, prompt: Text("napr. zľava po dohode, vrátenie, chybná suma"), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Vytvoriť koncept dobropisu") {
                    model.run { let d = try model.store.creditNoteDraft(for: inv.id, reason: reason); model.reload(); model.selection = .invoice(d.id) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
