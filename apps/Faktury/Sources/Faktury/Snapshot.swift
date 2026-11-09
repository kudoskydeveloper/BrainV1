import AppKit
import FakturyCore
import SwiftUI

/// `Faktury --snapshot <dir>`: renders the main views with sample data (in a temporary database) to PNG, light and dark,
/// and quits. For checking the design without clicking through the app.
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        // `Faktury --demo <dir>`: the real app over a separate database with sample data (for trying things out).
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            setenv("FAKTURY_DIR", dir.path, 1)
            setenv("FAKTURY_BACKUP_DIR", dir.appendingPathComponent("icloud").path, 1)
            if let s = try? Store(dir: dir), s.companies().isEmpty { s.notify = false; try? seed(s) }
            return
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("faktury-snapshot-\(UUID().uuidString)")
        setenv("FAKTURY_BACKUP_DIR", tmp.appendingPathComponent("icloud").path, 1)
        guard let store = try? Store(dir: tmp) else { print("store failed"); exit(1) }
        store.notify = false
        let model = AppModel(store: store)
        do { try seed(store) } catch { print("seed failed: \(error)"); exit(1) }
        model.reload()

        let draft = model.invoices.first(where: \.isDraft)!
        let issued = model.invoices.first { $0.status == .issued && $0.kind == .invoice }!
        let co = model.company(draft.companyId)!
        let pages: [(String, AnyView, CGSize)] = [
            ("list", AnyView(InvoiceList(model: model, folder: .all, items: model.invoices)), CGSize(width: 380, height: 640)),
            ("sidebar", AnyView(Sidebar(model: model)), CGSize(width: 240, height: 520)),
            ("editor", AnyView(InvoiceEditor(model: model, draft: draft, company: co)), CGSize(width: 1100, height: 1500)),
            ("detail", AnyView(InvoiceDetail(model: model, inv: issued, company: model.company(issued.companyId)!)), CGSize(width: 900, height: 420)),
            ("overview", AnyView(OverviewDetail(model: model, company: nil)), CGSize(width: 900, height: 900)),
            ("company", AnyView(CompanyEditor(model: model, company: co)), CGSize(width: 600, height: 1500)),
        ]
        for (name, view, size) in pages {
            for dark in [false, true] {
                let v = view.environment(\.snapshot, true).frame(width: size.width, height: size.height)
                    .background(dark ? Color(white: 0.12) : .white).environment(\.colorScheme, dark ? .dark : .light)
                let r = ImageRenderer(content: v)
                r.scale = 1
                guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("render failed \(name)"); continue }
                try? png.write(to: out.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
            }
            print("ok \(name)")
        }
        exit(0)
    }

    static func seed(_ s: Store) throws {
        var a = Company()
        a.name = "Vzorová Firma s.r.o."; a.legalForm = .company; a.street = "Hlavná 10"; a.city = "Bratislava"; a.zip = "821 09"
        a.ico = "54123456"; a.dic = "2121234567"; a.icDph = "SK2121234567"; a.vatPayer = true; a.iban = "SK3112000000198742637541"; a.swift = "TATRSKBX"
        a.registry = "Zapísaná v OR Mestského súdu Bratislava III, oddiel Sro, vložka č. 123456/B"; a.email = "faktury@firma.example"; a.web = "firma.example"
        a.issuedBy = "Ján Vzor"; a.color = "indigo"
        a = try s.save(a)
        var b = Company()
        b.name = "Ján Vzor"; b.legalForm = .soleTrader; b.street = "Hlavná 1"; b.city = "Trnava"; b.zip = "917 01"; b.ico = "51234567"; b.dic = "1081234567"
        b.iban = "SK3112000000198742637541"; b.registry = "Zapísaný v Živnostenskom registri Okresného úradu Trnava, č. 230-12345"; b.color = "orange"
        b = try s.save(b)
        var c1 = Client(); c1.name = "Odberateľ, a.s."; c1.street = "Dlhá 1"; c1.city = "Mesto"; c1.zip = "900 00"; c1.ico = "12345678"
        c1.dic = "2020000000"; c1.icDph = "SK2020000000"; c1.email = "klient@gmail.example"
        c1 = try s.save(c1)
        var c2 = Client(); c2.name = "Klient Mesto s.r.o."; c2.street = "Krátka 2"; c2.city = "Trnava"; c2.zip = "917 01"; c2.ico = "36123456"
        c2 = try s.save(c2)
        var d = try s.newDraft(companyId: a.id, client: c1)
        d.items = [Item(description: "Webová stránka priklad-web.sk – návrh a vývoj", quantity: 1, unit: "ks", unitPriceCents: 174_500, vatRate: 23),
                   Item(description: "Správa webu (november)", quantity: 6, unit: "hod", unitPriceCents: 4_000, vatRate: 23)]
        d.note = "Ďakujeme za spoluprácu."
        let issued1 = try s.issue(try s.saveDraft(d).id)
        try s.addPayment(issued1.id, amountCents: 50_000)
        var d2 = try s.newDraft(companyId: b.id, client: c2)
        d2.items = [Item(description: "Konzultácie", quantity: 10, unit: "hod", unitPriceCents: 5_000, vatRate: 0)]
        d2.issueDate = Day.adding(-40, to: Day.today); d2.deliveryDate = d2.issueDate; d2.dueDate = Day.adding(14, to: d2.issueDate)
        _ = try s.issue(try s.saveDraft(d2).id)
        var d3 = try s.newDraft(companyId: a.id, client: c2)
        d3.items = [Item(description: "Kampaň na sociálnych sieťach", quantity: 1, unit: "mes", unitPriceCents: 89_000, vatRate: 23),
                    Item(description: "Fotografie", quantity: 12, unit: "ks", unitPriceCents: 2_500, vatRate: 23)]
        _ = try s.saveDraft(d3)
    }
}
