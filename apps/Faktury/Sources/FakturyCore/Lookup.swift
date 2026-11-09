import Foundation

/// Slovak companies by IČO: name, address and DIČ from the Register účtovných závierok (RegisterUZ, free, no key),
/// IČ DPH confirmed in the EU VIES service. EU VAT numbers straight from VIES. (RPO of the Statistical Office would also do
/// names, but its API did not answer when this was built.)
public enum CompanyLookup {
    static func get(_ url: String, timeout: TimeInterval = 10) async throws -> Any {
        guard let u = URL(string: url) else { throw FakturyError("Zlá adresa.") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Faktury/0.1", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FakturyError("Register odpovedal \((resp as? HTTPURLResponse)?.statusCode ?? 0).") }
        return try JSONSerialization.jsonObject(with: data)
    }

    public static func byICO(_ ico: String) async throws -> Client? {
        let digits = ico.filter(\.isNumber)
        guard digits.count >= 6 else { throw FakturyError("IČO má mať 8 číslic.") }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let list = try await get("https://www.registeruz.sk/cruz-public/api/uctovne-jednotky?zmenene-od=2000-01-01&ico=\(padded)") as? [String: Any]
        guard let ids = list?["id"] as? [Int], !ids.isEmpty else { return nil }
        var best: [String: Any]?
        for id in ids.suffix(3) {
            guard let d = try await get("https://www.registeruz.sk/cruz-public/api/uctovna-jednotka?id=\(id)") as? [String: Any] else { continue }
            if d["datumZrusenia"] == nil || best == nil { best = d }
        }
        guard let d = best else { return nil }
        var c = Client()
        c.name = d["nazovUJ"] as? String ?? ""
        c.street = d["ulica"] as? String ?? ""
        c.city = d["mesto"] as? String ?? ""
        let psc = (d["psc"] as? String ?? "").filter(\.isNumber)
        c.zip = psc.count == 5 ? "\(psc.prefix(3)) \(psc.suffix(2))" : psc
        c.ico = padded
        c.dic = d["dic"] as? String ?? ""
        c.source = "registeruz"
        if !c.dic.isEmpty, let v = try? await vies("SK", c.dic), v.valid { c.icDph = "SK\(c.dic)" }
        return c
    }

    public struct VIES { public let valid: Bool; public let name: String; public let address: String }

    public static func vies(_ country: String, _ number: String) async throws -> VIES {
        let n = number.uppercased().replacingOccurrences(of: " ", with: "")
        let num = n.hasPrefix(country.uppercased()) ? String(n.dropFirst(2)) : n
        guard let d = try await get("https://ec.europa.eu/taxation_customs/vies/rest-api/ms/\(country.uppercased())/vat/\(num)") as? [String: Any] else {
            throw FakturyError("VIES neodpovedá.")
        }
        func clean(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "---", with: "") }
        return VIES(valid: d["isValid"] as? Bool ?? false, name: clean(d["name"] as? String), address: clean(d["address"] as? String))
    }

    /// An EU business from its VAT number (e.g. CZ12345678, ATU12345678). Address comes as free text; split best effort.
    public static func byVAT(_ vat: String) async throws -> Client? {
        let t = vat.uppercased().replacingOccurrences(of: " ", with: "")
        guard t.count > 4, t.prefix(2).allSatisfy(\.isLetter) else { throw FakturyError("IČ DPH začína kódom krajiny, napr. CZ12345678.") }
        let cc = String(t.prefix(2))
        let v = try await vies(cc == "EL" ? "EL" : cc, t)
        guard v.valid else { return nil }
        var c = Client()
        c.name = v.name
        c.icDph = t
        c.country = cc == "EL" ? "GR" : cc
        let lines = v.address.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = lines.first { c.street = first }
        if lines.count > 1 {
            let l = lines[1]
            if let r = l.range(of: #"^[0-9A-Z\- ]{4,8}\s"#, options: .regularExpression) { c.zip = l[r].trimmingCharacters(in: .whitespaces); c.city = String(l[r.upperBound...]) }
            else { c.city = l }
        }
        if cc == "SK" { c.dic = String(t.dropFirst(2)); c.country = "SK" }
        c.source = "vies"
        return c
    }

    /// IČO, or an EU VAT number.
    public static func find(_ query: String) async throws -> Client? {
        let t = query.trimmingCharacters(in: .whitespaces)
        if t.prefix(2).allSatisfy(\.isLetter) && t.count > 4 { return try await byVAT(t) }
        return try await byICO(t)
    }
}
