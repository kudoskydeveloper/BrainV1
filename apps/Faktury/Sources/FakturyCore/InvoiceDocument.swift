import AppKit
import SwiftUI

public enum Palette {
    public static let names = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "gray"]
    public static func color(_ name: String) -> Color {
        switch name {
        case "indigo": .indigo; case "purple": .purple; case "pink": .pink; case "red": .red; case "orange": .orange
        case "yellow": .yellow; case "green": .green; case "mint": .mint; case "teal": .teal; case "gray": .gray
        default: .blue
        }
    }
    public static func label(_ name: String) -> String {
        ["blue": "Modrá", "indigo": "Indigová", "purple": "Fialová", "pink": "Ružová", "red": "Červená", "orange": "Oranžová",
         "yellow": "Žltá", "green": "Zelená", "mint": "Mätová", "teal": "Tyrkysová", "gray": "Sivá"][name] ?? name
    }
}

/// A4 in points.
public enum A4 { public static let size = CGSize(width: 595.28, height: 841.89) }

/// The printed invoice, one page. The editor shows the same view as its live preview, so the PDF looks exactly like it.
public struct InvoicePage: View {
    let inv: Invoice
    let company: Company
    let items: [Item]
    let page: Int
    let pages: Int
    let qr: [[Bool]]?

    public init(inv: Invoice, company: Company, items: [Item], page: Int, pages: Int, qr: [[Bool]]?) {
        self.inv = inv; self.company = company; self.items = items; self.page = page; self.pages = pages; self.qr = qr
    }

    var first: Bool { page == 1 }
    var last: Bool { page == pages }
    var accent: Color { Palette.color(company.color) }
    var vat: Bool { inv.vatMode.chargesVat }
    var t: Totals { inv.totals }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if first {
                parties.padding(.top, 22)
                dates.padding(.top, 18)
            }
            table.padding(.top, first ? 22 : 18)
            if last {
                summary.padding(.top, 14)
                notes.padding(.top, 14)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 42)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: A4.size.width, height: A4.size.height, alignment: .topLeading)
        .background(Color.white)
        .overlay { if inv.isDraft { watermark } }
        .foregroundStyle(Color(white: 0.12))
        .font(.system(size: 8.5))
        .environment(\.colorScheme, .light)
    }

    // MARK: Parts

    var header: some View {
        HStack(alignment: .top) {
            HStack(alignment: .center, spacing: 10) {
                if let logo = logo { Image(nsImage: logo).resizable().scaledToFit().frame(maxWidth: 120, maxHeight: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(company.name).font(.system(size: 15, weight: .semibold))
                    if !company.web.isEmpty || !company.email.isEmpty {
                        Text([company.web, company.email].filter { !$0.isEmpty }.joined(separator: "  ·  ")).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(inv.kind.pdfTitle.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(1.2).foregroundStyle(accent)
                Text(inv.number ?? "KONCEPT").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                if pages > 1 { Text("Strana \(page) z \(pages)").font(.system(size: 7.5)).foregroundStyle(.secondary) }
            }
        }
    }

    var logo: NSImage? { company.logoPath.isEmpty ? nil : NSImage(contentsOfFile: company.logoPath) }

    var parties: some View {
        HStack(alignment: .top, spacing: 16) {
            party("Dodávateľ", name: company.name, lines: company.addressLines, ids: supplierIDs, boxed: false)
            party("Odberateľ", name: inv.client.name, lines: inv.client.addressLines, ids: clientIDs, boxed: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var supplierIDs: [(String, String)] {
        var out: [(String, String)] = []
        if !company.ico.isEmpty { out.append(("IČO", company.ico)) }
        if !company.dic.isEmpty { out.append(("DIČ", company.dic)) }
        if company.vatPayer && !company.icDph.isEmpty { out.append(("IČ DPH", company.icDph)) }
        if !company.vatPayer { out.append(("", "Nie je platiteľ DPH")) }
        return out
    }

    var clientIDs: [(String, String)] {
        var out: [(String, String)] = []
        if !inv.client.ico.isEmpty { out.append(("IČO", inv.client.ico)) }
        if !inv.client.dic.isEmpty { out.append(("DIČ", inv.client.dic)) }
        if !inv.client.icDph.isEmpty { out.append(("IČ DPH", inv.client.icDph)) }
        return out
    }

    func party(_ title: String, name: String, lines: [String], ids: [(String, String)], boxed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 7, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            Text(name.isEmpty ? "—" : name).font(.system(size: 10.5, weight: .semibold)).padding(.top, 2)
            ForEach(lines, id: \.self) { Text($0) }
            if !ids.isEmpty {
                VStack(alignment: .leading, spacing: 1.5) {
                    ForEach(ids, id: \.1) { k, v in
                        HStack(spacing: 4) {
                            if !k.isEmpty { Text(k).foregroundStyle(.secondary).frame(width: 34, alignment: .leading) }
                            Text(v).monospacedDigit()
                        }
                    }
                }
                .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(boxed ? 12 : 0)
        .padding(.top, boxed ? 0 : 12)
        .background(boxed ? Color(white: 0.965) : .clear, in: .rect(cornerRadius: 8))
    }

    var dates: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                field("Dátum vystavenia", Day.sk(inv.issueDate)).frame(width: col, alignment: .leading)
                field(inv.kind == .creditNote ? "Dátum opravy" : "Dátum dodania", Day.sk(inv.deliveryDate)).frame(width: col, alignment: .leading)
                field(inv.kind == .creditNote ? "Dátum vrátenia" : "Dátum splatnosti", Day.sk(inv.dueDate), strong: inv.kind != .creditNote).frame(width: col, alignment: .leading)
                field("Forma úhrady", inv.paymentMethod.label).frame(width: col, alignment: .leading)
            }
            if inv.paymentMethod == .transfer {
                HStack(alignment: .top, spacing: 0) {
                    field("IBAN", Validation.formatIBAN(company.iban)).frame(width: col * 2, alignment: .leading)
                    field("SWIFT / BIC", company.swift.isEmpty ? "—" : company.swift).frame(width: col, alignment: .leading)
                    field("Variabilný symbol", vs, strong: true).frame(width: col, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.88)).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.88)).frame(height: 0.5) }
    }

    var vs: String { inv.variableSymbol.isEmpty ? String((inv.number ?? "").filter(\.isNumber).suffix(10)) : inv.variableSymbol }

    /// A quarter of the text width.
    var col: CGFloat { (A4.size.width - 84) / 4 }

    func field(_ k: String, _ v: String, strong: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 7)).foregroundStyle(.secondary)
            Text(v.isEmpty ? "—" : v).font(.system(size: 9, weight: strong ? .semibold : .regular)).monospacedDigit()
        }
    }

    // MARK: Items

    var table: some View {
        VStack(spacing: 0) {
            row(desc: "Popis", qty: "Množstvo", unit: "MJ", price: vat ? "Cena/MJ bez DPH" : "Cena/MJ", rate: "DPH", total: vat ? "Spolu bez DPH" : "Spolu", header: true)
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.75)).frame(height: 0.5) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                row(desc: it.description, qty: Money.quantity(it.quantity), unit: it.unit, price: Money.plain(it.unitPriceCents),
                    rate: Money.rate(it.vatRate), total: Money.plain(it.netCents), header: false)
                    .padding(.vertical, 5.5)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.92)).frame(height: 0.5) }
            }
        }
    }

    func row(desc: String, qty: String, unit: String, price: String, rate: String, total: String, header: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(desc).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text(qty).frame(width: 46, alignment: .trailing)
            Text(unit).frame(width: 30, alignment: .leading)
            Text(price).frame(width: 70, alignment: .trailing)
            if vat { Text(rate).frame(width: 32, alignment: .trailing) }
            Text(total).frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: header ? 7 : 8.5, weight: header ? .semibold : .regular))
        .foregroundStyle(header ? Color.secondary : Color(white: 0.12))
        .monospacedDigit()
    }

    // MARK: Totals and QR

    var summary: some View {
        HStack(alignment: .top, spacing: 20) {
            if let qr, inv.paymentMethod == .transfer, inv.kind != .creditNote {
                VStack(spacing: 4) {
                    QRShape(matrix: qr).fill(Color.black).frame(width: 96, height: 96)
                    Text("PAY by square").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(white: 0.85), lineWidth: 0.75))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if vat {
                    HStack(spacing: 8) {
                        Text("Sadzba").frame(width: 40, alignment: .trailing)
                        Text("Základ").frame(width: 72, alignment: .trailing)
                        Text("DPH").frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(t.groups, id: \.rate) { g in
                        HStack(spacing: 8) {
                            Text(Money.rate(g.rate)).frame(width: 40, alignment: .trailing)
                            Text(Money.plain(g.baseCents)).frame(width: 72, alignment: .trailing)
                            Text(Money.plain(g.vatCents)).frame(width: 64, alignment: .trailing)
                        }
                        .monospacedDigit()
                    }
                    Rectangle().fill(Color(white: 0.85)).frame(width: 192, height: 0.5).padding(.vertical, 2)
                    total("Spolu bez DPH", t.subtotalCents)
                    total("DPH", t.vatCents)
                } else if inv.vatMode == .reverseCharge {
                    total("Základ dane", t.subtotalCents)
                    total("DPH", 0)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(inv.kind == .creditNote ? "Suma dobropisu" : (inv.kind == .proforma ? "Záloha na úhradu" : "Na úhradu"))
                        .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                    Text(Money.string(t.totalCents, currency: inv.currency)).font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(accent)
                }
                .padding(.top, 6)
            }
        }
    }

    func total(_ k: String, _ cents: Int) -> some View {
        HStack(spacing: 8) {
            Text(k).foregroundStyle(.secondary)
            Text(Money.string(cents, currency: inv.currency)).frame(width: 90, alignment: .trailing).monospacedDigit()
        }
    }

    var noteLines: [String] {
        var out: [String] = []
        if inv.kind == .creditNote {
            out.append("Opravná faktúra (dobropis) k faktúre č. \(inv.creditsNumber ?? "…")\(inv.creditsIssueDate.map { " zo dňa \(Day.sk($0))" } ?? "").")
            if !inv.creditReason.isEmpty { out.append("Dôvod opravy: \(inv.creditReason)") }
        }
        if inv.kind == .proforma { out.append("Zálohová faktúra nie je daňový doklad. Daňový doklad vystavíme po prijatí platby.") }
        if inv.vatMode == .reverseCharge { out.append(inv.vatNote.isEmpty ? "Prenesenie daňovej povinnosti" : inv.vatNote) }
        else if !inv.vatNote.isEmpty { out.append(inv.vatNote) }
        if !inv.note.isEmpty { out.append(inv.note) }
        return out
    }

    var notes: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(noteLines, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(Color(white: 0.88)).frame(height: 0.5).padding(.bottom, 5)
            if !company.footerNote.isEmpty && last { Text(company.footerNote) }
            HStack(alignment: .top) {
                Text(company.registry).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if !company.issuedBy.isEmpty { Text("Vystavil: \(company.issuedBy)") }
            }
            let contact = [company.phone, company.email, company.web].filter { !$0.isEmpty }
            if !contact.isEmpty { Text(contact.joined(separator: "  ·  ")) }
        }
        .font(.system(size: 7))
        .foregroundStyle(.secondary)
    }

    var watermark: some View {
        Text("KONCEPT").font(.system(size: 96, weight: .bold)).foregroundStyle(Color.gray.opacity(0.10)).rotationEffect(.degrees(-30))
    }
}

/// The QR code as vector squares (sharp at any zoom and print).
public struct QRShape: Shape {
    let matrix: [[Bool]]
    public init(matrix: [[Bool]]) { self.matrix = matrix }
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = CGFloat(max(matrix.count, 1)), cell = min(rect.width, rect.height) / n
        for (y, row) in matrix.enumerated() {
            var x = 0
            while x < row.count {
                guard row[x] else { x += 1; continue }
                var end = x
                while end < row.count && row[end] { end += 1 }
                p.addRect(CGRect(x: rect.minX + CGFloat(x) * cell, y: rect.minY + CGFloat(y) * cell, width: CGFloat(end - x) * cell + 0.01, height: cell + 0.01))
                x = end
            }
        }
        return p
    }
}

public enum InvoicePDF {
    /// Items split over pages: up to 12 rows fit on a single page with everything; otherwise 18 on the first, 30 on the next,
    /// and the last page keeps room for the totals.
    public static func pages(_ items: [Item]) -> [[Item]] {
        if items.count <= 12 { return [items] }
        var out: [[Item]] = [], rest = items[...], cap = 18
        while !rest.isEmpty {
            let take = min(cap, rest.count)
            out.append(Array(rest.prefix(take))); rest = rest.dropFirst(take); cap = 30
        }
        if out.count > 1, let lastPage = out.last, lastPage.count > 20 {
            out[out.count - 1] = Array(lastPage.prefix(lastPage.count - 6)); out.append(Array(lastPage.suffix(6)))
        }
        return out
    }

    public static func qr(_ inv: Invoice, company: Company) -> [[Bool]]? {
        guard inv.paymentMethod == .transfer, inv.kind != .creditNote, inv.totals.totalCents > 0, !company.iban.isEmpty else { return nil }
        var p = PayBySquare.Payment(amount: Money.decimal(inv.totals.totalCents), iban: company.iban)
        p.currency = inv.currency
        p.dueDate = inv.dueDate
        p.variableSymbol = inv.variableSymbol.isEmpty ? String((inv.number ?? "").filter(\.isNumber).suffix(10)) : inv.variableSymbol
        p.swift = company.swift
        p.note = "\(inv.kind.title) \(inv.number ?? "")".trimmingCharacters(in: .whitespaces)
        p.beneficiaryName = company.name
        p.beneficiaryStreet = company.street
        p.beneficiaryCity = [company.zip, company.city].filter { !$0.isEmpty }.joined(separator: " ")
        return (try? PayBySquare.encode(p)).flatMap(PayBySquare.qrMatrix)
    }

    /// Every page as a view (the editor preview uses the same).
    public static func views(_ inv: Invoice, company: Company) -> [InvoicePage] {
        let chunks = pages(inv.items), code = qr(inv, company: company)
        return chunks.enumerated().map { n, items in InvoicePage(inv: inv, company: company, items: items, page: n + 1, pages: chunks.count, qr: code) }
    }

    @MainActor
    public static func render(_ inv: Invoice, company: Company) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: A4.size)
        let info: [CFString: Any] = [kCGPDFContextTitle: "\(inv.kind.title) \(inv.number ?? "")", kCGPDFContextAuthor: company.name, kCGPDFContextCreator: "Faktúry"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { throw FakturyError("PDF sa nepodarilo vytvoriť.") }
        for page in views(inv, company: company) {
            let r = ImageRenderer(content: page)
            r.proposedSize = ProposedViewSize(A4.size)
            r.render { _, draw in
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        guard data.length > 1000 else { throw FakturyError("PDF je prázdne.") }
        return data as Data
    }
}
