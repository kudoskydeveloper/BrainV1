import FakturyCore
import SwiftUI

struct TemplateList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.templates.isEmpty {
                ContentUnavailableView {
                    Label("Zatiaľ žiadne šablóny", systemImage: "doc.on.doc")
                } description: {
                    Text("Šablóna je opakovaná faktúra (rovnaký odberateľ a položky). Ulož ju z konceptu alebo vystavenej faktúry cez „Uložiť ako šablónu…“ a nový koncept z nej vytvoríš jedným klikom.")
                }
            } else {
                List(selection: $model.selection) {
                    ForEach(model.companies) { c in
                        let list = model.templates.filter { $0.companyId == c.id }
                        if !list.isEmpty {
                            Section(c.shortName) {
                                ForEach(list) { t in
                                    HStack(alignment: .top, spacing: 10) {
                                        CompanyMark(company: c, size: 22).padding(.top, 1)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(t.name).font(.body.weight(.medium)).lineLimit(1)
                                                Spacer(minLength: 6)
                                                Text(Money.string(t.totalCents)).monospacedDigit()
                                            }
                                            Text(t.client.name.isEmpty ? "Bez odberateľa" : t.client.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .tag(Pick.template(t.id))
                                    .contextMenu {
                                        Button("Vytvoriť faktúru") { model.newInvoice(fromTemplate: t.id) }
                                        Button("Zmazať šablónu", role: .destructive) { model.run { try model.store.deleteTemplate(t.id) } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Šablóny")
        .navigationSubtitle("\(model.templates.count)")
    }
}

struct TemplateDetail: View {
    @ObservedObject var model: AppModel
    let template: InvoiceTemplate
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var company: Company? { model.company(template.companyId) }

    var body: some View {
        Page {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        CompanyMark(company: company, size: 20)
                        Text(company?.shortName ?? "").foregroundStyle(.secondary)
                        Pill(text: "Šablóna", color: .purple, symbol: "doc.on.doc")
                    }
                    Text(template.name).font(.title2.weight(.semibold))
                    Text("\(template.kind.title) · splatnosť \(template.dueDays ?? company?.dueDays ?? 14) dní · \(template.vatMode.label)").foregroundStyle(.secondary)
                }
                Spacer()
                Text(Money.string(template.totalCents)).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            HStack {
                Button { model.newInvoice(fromTemplate: template.id) } label: { Label("Vytvoriť faktúru", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderedProminent)
                Button("Premenovať…") { newName = template.name; renaming = true }
                Spacer()
                Button("Zmazať", role: .destructive) { confirmDelete = true }
            }
            Card("Odberateľ", symbol: "person.crop.square", tint: .teal) {
                Text(template.client.name.isEmpty ? "—" : template.client.name).font(.body.weight(.medium))
                if !template.client.addressLines.isEmpty { Text(template.client.addressLines.joined(separator: ", ")).foregroundStyle(.secondary) }
                if !template.client.email.isEmpty { Label(template.client.email, systemImage: "envelope").font(.callout).foregroundStyle(.secondary) }
            }
            Card("Položky", symbol: "list.bullet", tint: .blue) {
                ForEach(template.items) { it in
                    HStack {
                        Text(it.description.isEmpty ? "—" : it.description)
                        Spacer()
                        Text("\(Money.quantity(it.quantity)) \(it.unit) × \(Money.plain(it.unitPriceCents))").foregroundStyle(.secondary).monospacedDigit()
                        Text(Money.string(it.netCents)).monospacedDigit().frame(minWidth: 90, alignment: .trailing)
                    }
                }
                if !template.note.isEmpty { Text(template.note).font(.callout).foregroundStyle(.secondary) }
            }
            Text("Úprava šablóny: vytvor z nej faktúru, v koncepte zmeň čo treba a ulož ju znova ako šablónu s rovnakým názvom – prepíše sa.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle(template.name)
        .alert("Premenovať šablónu", isPresented: $renaming) {
            TextField("Názov", text: $newName)
            Button("Uložiť") { var t = template; t.name = newName; model.run { _ = try model.store.save(t) } }
            Button("Zrušiť", role: .cancel) {}
        }
        .confirmationDialog("Zmazať šablónu \(template.name)?", isPresented: $confirmDelete) {
            Button("Zmazať", role: .destructive) { model.run { try model.store.deleteTemplate(template.id) }; model.selection = nil }
        } message: { Text("Faktúry vytvorené zo šablóny ostanú.") }
    }
}

/// Name for a new template (an existing one with the same name for the subject is replaced).
struct TemplateNameSheet: View {
    @ObservedObject var model: AppModel
    let source: Invoice
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var existing: Bool { model.templates.contains { $0.companyId == source.companyId && $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uložiť ako šablónu").font(.title3.weight(.semibold))
            Text("Uloží sa odberateľ, položky, DPH, splatnosť a poznámka. Dátumy a číslo sa doplnia pri každej novej faktúre.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Názov šablóny", text: $name).textFieldStyle(.roundedBorder)
            if existing { Text("Šablóna s týmto názvom už existuje – prepíše sa.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing ? "Prepísať šablónu" : "Uložiť šablónu") {
                    model.run {
                        let t = try model.store.saveTemplate(from: source.id, name: name)
                        model.toast = "Šablóna „\(t.name)“ je uložená."
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            let first = source.items.first?.description ?? ""
            name = [source.client.name, first].filter { !$0.isEmpty }.joined(separator: " – ")
        }
    }
}
