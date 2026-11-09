import SwiftUI

/// What a form sheet edits. One enum so the window has one `.sheet(item:)`.
enum Editor: Identifiable {
    case lostReason(Business, Deal, String)          // dragged to a lost column: why
    case nextStep(Business, Deal)
    case note(Business, account: String?, deal: Deal?)
    case task(Business, account: String?, deal: Deal?)
    case deal(Business, account: String, Deal?)
    case newAccount(Business, lead: Bool)
    case contact(Business, account: String)
    case company(Business, account: String, AccountDetail.Company?)

    var id: String {
        switch self {
        case .lostReason(_, let d, _): "lost\(d.id)"
        case .nextStep(_, let d): "next\(d.id)"
        case .note(_, let a, let d): "note\(a ?? "")\(d?.id ?? "")"
        case .task(_, let a, let d): "task\(a ?? "")\(d?.id ?? "")"
        case .deal(_, let a, let d): "deal\(a)\(d?.id ?? "new")"
        case .newAccount(let b, let lead): "acc\(b.id)\(lead)"
        case .contact(_, let a): "contact\(a)"
        case .company(_, let a, let c): "company\(a)\(c?.id ?? "new")"
        }
    }
}

/// The window's editing state, passed down so any view can open a form.
@MainActor
final class Editing: ObservableObject {
    @Published var editor: Editor?
}

enum Moves {
    /// A card dropped on another column. Lost asks why first; everything else moves at once (the board changes before the CRM
    /// answers and goes back if it refuses).
    @MainActor static func drop(_ dealID: String, on stage: Stage, in b: Business, store: Store, editing: Editing) {
        guard let d = b.deals.first(where: { $0.id == dealID }), d.stage != stage.key else { return }
        if stage.kind == "lost" { editing.editor = .lostReason(b, d, stage.key); return }
        move(d, to: stage.key, in: b, store: store)
    }

    @MainActor static func move(_ d: Deal, to stage: String, in b: Business, lostReason: String? = nil, store: Store) {
        var args: [String: Any] = ["deal": d.ref ?? d.id, "stage": stage]
        if let lostReason { args["lostReason"] = lostReason }
        let label = b.stage(stage)?.label ?? stage
        store.act(b.id, "move_deal", args, done: "\(d.title) → \(label)", reload: d.accountId) { o in
            guard let bi = o.businesses.firstIndex(where: { $0.id == b.id }), let di = o.businesses[bi].deals.firstIndex(where: { $0.id == d.id }) else { return }
            o.businesses[bi].deals[di].stage = stage
        }
    }
}

struct EditorSheet: View {
    let editor: Editor
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss

    // one set of fields, used by whichever form is open
    @State private var text = ""
    @State private var text2 = ""
    @State private var text3 = ""
    @State private var text4 = ""
    @State private var text5 = ""
    @State private var text6 = ""
    @State private var text7 = ""
    @State private var hasDate = false
    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
    @State private var kind = "note"
    @State private var number = ""
    @State private var number2 = ""
    @State private var stage = ""

    var body: some View {
        Form { fields }
            .formStyle(.grouped)
            .frame(width: 480)
            .onAppear(perform: prefill)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zrušiť") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saveTitle) { save(); dismiss() }.disabled(!valid) }
            }
    }

    var day: String? { hasDate ? date.formatted(.iso8601.year().month().day()) : nil }

    @ViewBuilder var fields: some View {
        switch editor {
        case .lostReason(_, let d, _):
            Section { TextField("Dôvod", text: $text, prompt: Text("napr. vybrali konkurenciu, bez rozpočtu")) } header: { Text("Prečo sa „\(d.title)“ prehral?") }
        case .nextStep(let b, let d):
            Section {
                TextField("Ďalší krok", text: $text, prompt: Text("napr. poslať ponuku, zavolať"), axis: .vertical).lineLimit(2...5)
                Toggle("Termín", isOn: $hasDate)
                if hasDate { DatePicker("Kedy", selection: $date, displayedComponents: .date) }
            } header: { Text(d.title) } footer: {
                if b.id == "kudosky" { Text("V Kuboarde je ďalší krok najbližšia otvorená úloha obchodu, takže sa pridá ako úloha.").foregroundStyle(.secondary) }
            }
        case .note(let b, _, let d):
            Section {
                TextField("Poznámka", text: $text, prompt: Text("čo sa stalo a čo z toho vyplýva"), axis: .vertical).lineLimit(3...10)
                if b.id == "kudosky" {
                    Picker("Druh", selection: $kind) { Text("Poznámka").tag("note"); Text("Telefonát").tag("call"); Text("E-mail").tag("email"); Text("Stretnutie").tag("meeting") }
                        .pickerStyle(.segmented)
                }
            } header: { Text(d.map { "K obchodu \($0.title)" } ?? "Ku klientovi") }
        case .task(_, _, let d):
            Section {
                TextField("Úloha", text: $text, prompt: Text("napr. poslať zmluvu"))
                Toggle("Termín", isOn: $hasDate)
                if hasDate { DatePicker("Kedy", selection: $date, displayedComponents: .date) }
            } header: { Text(d.map { "K obchodu \($0.title)" } ?? "Ku klientovi") }
        case .deal(let b, _, let d):
            Section {
                TextField("Názov", text: $text, prompt: Text(b.id == "kudosky" ? "napr. 60 sedadiel, Pro" : "napr. Web a rezervácie"))
                if d == nil {
                    Picker("Fáza", selection: $stage) { ForEach(b.openStages) { Text($0.label).tag($0.key) } }
                }
                if b.id == "kudosky" {
                    TextField("Sedadlá", text: $number).frame(maxWidth: 200)
                    TextField("€ za sedadlo mesačne", text: $number2).frame(maxWidth: 200)
                } else {
                    TextField("Hodnota (€)", text: $number).frame(maxWidth: 200)
                }
                Toggle("Očakávané uzavretie", isOn: $hasDate)
                if hasDate { DatePicker("Kedy", selection: $date, displayedComponents: .date) }
            } header: { Text(d == nil ? "Nový obchod" : "Upraviť obchod") }
        case .newAccount(let b, let lead):
            Section {
                TextField("Názov firmy", text: $text)
                TextField("Web", text: $text2, prompt: Text("firma.sk"))
                TextField("Zdroj", text: $text3, prompt: Text("napr. Odporúčanie, LinkedIn, Web"))
                if !lead { TextField("Poznámka", text: $text4, axis: .vertical).lineLimit(1...4) }
            } header: { Text(lead ? "Nový lead (\(b.name))" : "Nový klient (\(b.name))") }
        case .contact:
            Section {
                TextField("Meno", text: $text)
                TextField("Priezvisko", text: $text2)
                TextField("Pozícia", text: $text3)
                TextField("E-mail", text: $text4)
                TextField("Telefón", text: $text5)
            } header: { Text("Nový kontakt") }
        case .company:
            Section {
                TextField("Obchodné meno", text: $text)
                TextField("IČO", text: $text2)
                TextField("DIČ", text: $text3)
                TextField("IČ DPH", text: $text4)
                TextField("Faktúry na e-mail", text: $text5)
                TextField("Ulica", text: $text6)
                TextField("Mesto a PSČ", text: $text7, prompt: Text("Bratislava, 831 04"))
            } header: { Text("Fakturačné údaje") } footer: { Text("Podľa IČO sa k nim priradia faktúry vo Faktúrach.").foregroundStyle(.secondary) }
        }
    }

    var saveTitle: String {
        switch editor {
        case .lostReason: "Presunúť do Prehraté"
        case .newAccount, .contact: "Pridať"
        case .deal(_, _, let d): d == nil ? "Založiť" : "Uložiť"
        default: "Uložiť"
        }
    }

    var valid: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch editor {
        case .contact: return !t.isEmpty || !text2.trimmingCharacters(in: .whitespaces).isEmpty
        case .company: return !text2.trimmingCharacters(in: .whitespaces).isEmpty || !t.isEmpty
        case .nextStep: return true
        default: return !t.isEmpty
        }
    }

    func prefill() {
        switch editor {
        case .nextStep(_, let d):
            text = d.nextStep ?? ""
            if let on = d.nextStepOn.flatMap(Fmt.day) { hasDate = true; date = on }
        case .deal(let b, _, let d):
            stage = b.openStages.first?.key ?? ""
            if let d {
                text = d.title
                if b.id == "kudosky" { number = d.seats.map(String.init) ?? "" } else { number = d.value.map { String(format: "%g", $0) } ?? "" }
                if let c = d.expectedCloseOn.flatMap(Fmt.day) { hasDate = true; date = c }
            }
        case .company(_, _, let c):
            if let c { text = c.legalName ?? ""; text2 = c.registrationNo ?? ""; text3 = c.taxId ?? ""; text4 = c.vatId ?? ""; text5 = c.billingEmail ?? ""; text6 = c.address ?? "" }
        default: break
        }
    }

    func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }) }
        switch editor {
        case .lostReason(let b, let d, let stageKey):
            Moves.move(d, to: stageKey, in: b, lostReason: t, store: store)
        case .nextStep(let b, let d):
            var a: [String: Any] = ["deal": d.ref ?? d.id, "text": t]
            if let day { a["on"] = day }
            store.act(b.id, "next_step", a, done: "Ďalší krok uložený", reload: d.accountId) { o in
                guard b.id == "10t", let bi = o.businesses.firstIndex(where: { $0.id == b.id }), let di = o.businesses[bi].deals.firstIndex(where: { $0.id == d.id }) else { return }
                o.businesses[bi].deals[di].nextStep = t.isEmpty ? nil : t
                o.businesses[bi].deals[di].nextStepOn = day
            }
        case .note(let b, let account, let d):
            var a: [String: Any] = ["body": t, "kind": kind]
            if let d { a["deal"] = d.ref ?? d.id } else if let account { a["account"] = account }
            store.act(b.id, "note_add", a, done: "Poznámka pridaná", reload: account ?? d?.accountId)
        case .task(let b, let account, let d):
            var a: [String: Any] = ["title": t]
            if let day { a["due"] = day }
            if let d { a["deal"] = d.ref ?? d.id } else if let account { a["account"] = account }
            store.act(b.id, "task_add", a, done: "Úloha pridaná", reload: account ?? d?.accountId)
        case .deal(let b, let account, let d):
            var a: [String: Any] = ["title": t]
            if let d { a["id"] = d.ref ?? d.id } else { a["account"] = account; a["stage"] = stage }
            if b.id == "kudosky" {
                if let s = num(number) { a["seats"] = Int(s) }
                if let p = num(number2) { a["pricePerSeat"] = p }
            } else if let v = num(number) { a["value"] = v }
            if let day { a["expectedCloseOn"] = day }
            store.act(b.id, "deal_save", a, done: d == nil ? "Obchod založený" : "Obchod uložený", reload: account)
        case .newAccount(let b, let lead):
            var a: [String: Any] = ["name": t, "lead": lead]
            if !text2.isEmpty { a["website"] = text2 }
            if !text3.isEmpty { a["source"] = text3 }
            if !text4.isEmpty { a["notes"] = text4 }
            store.act(b.id, "account_create", a, done: "\(t) pridaný do \(b.name)")
        case .contact(let b, let account):
            var a: [String: Any] = ["account": account, "firstName": t, "lastName": text2.trimmingCharacters(in: .whitespaces)]
            if !text3.isEmpty { a["position"] = text3 }
            if !text4.isEmpty { a["email"] = text4.trimmingCharacters(in: .whitespaces) }
            if !text5.isEmpty { a["phone"] = text5 }
            store.act(b.id, "contact_save", a, done: "Kontakt pridaný", reload: account)
        case .company(let b, let account, let c):
            var a: [String: Any] = ["account": account]
            if let c { a["id"] = c.id }
            for (k, v) in [("legalName", t), ("registrationNo", text2), ("taxId", text3), ("vatId", text4), ("billingEmail", text5), ("street", text6)] where !v.isEmpty { a[k] = v }
            if !text7.isEmpty {
                let parts = text7.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                a["city"] = parts.first ?? ""
                if parts.count > 1 { a["postalCode"] = parts[1] }
            }
            store.act(b.id, "company_save", a, done: "Fakturačné údaje uložené", reload: account)
        }
    }
}
