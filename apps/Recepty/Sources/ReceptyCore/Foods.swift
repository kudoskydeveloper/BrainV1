import Foundation

/// A food with nutrients per 100 g: from the bundled USDA database or from Open Food Facts.
public struct Food: Identifiable, Codable, Equatable, Sendable {
    /// "usda:171287" or "off:8588000282210".
    public var id: String
    public var name: String
    public var brand = ""
    public var category = ""
    public var per100: Nutrients
    /// Household measures: label → grams ("1 large" → 50).
    public var portions: [Portion] = []

    public struct Portion: Codable, Equatable, Sendable {
        public var label: String, grams: Double
    }

    public var source: String { id.hasPrefix("off:") ? "Open Food Facts" : "USDA" }
    public var displayName: String { brand.isEmpty ? name : "\(name) (\(brand))" }
}

/// The bundled USDA FoodData Central database (SR Legacy + Foundation Foods), read only. Names are English; the analysis
/// translates an ingredient into a search query first.
public final class FoodDB {
    public static let shared = try? FoodDB()
    let db: DB

    /// Next to the app (Contents/Resources), next to recepty-mcp (../Resources) or in the source tree while developing.
    public static var path: String? {
        let fm = FileManager.default
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("foods.sqlite")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        c.append(exe.appendingPathComponent("../Resources/foods.sqlite"))
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/foods.sqlite"))
        return c.map(\.standardizedFileURL.path).first { fm.fileExists(atPath: $0) }
    }

    public init(path: String? = nil) throws {
        guard let p = path ?? Self.path else { throw ReceptyError("Chýba databáza potravín (foods.sqlite).") }
        db = try DB(path: p, readOnly: true)
    }

    private func food(_ r: Row) -> Food {
        let id = r["id"]?.int64 ?? 0
        let n = Nutrients(kcal: r["kcal"]?.double ?? 0, protein: r["protein"]?.double ?? 0, fat: r["fat"]?.double ?? 0, carbs: r["carbs"]?.double ?? 0,
                          fiber: r["fiber"]?.double ?? 0, sugars: r["sugars"]?.double ?? 0, satFat: r["sat_fat"]?.double ?? 0, salt: r["salt"]?.double ?? 0)
        return Food(id: "usda:\(id)", name: r["name"]?.string ?? "", category: r["category"]?.string ?? "", per100: n)
    }

    public func food(_ ref: String) -> Food? {
        guard ref.hasPrefix("usda:"), let id = Int64(ref.dropFirst(5)), let r = try? db.run("SELECT * FROM foods WHERE id = ?", [id]).first else { return nil }
        var f = food(r)
        f.portions = portions(id)
        return f
    }

    func portions(_ id: Int64) -> [Food.Portion] {
        ((try? db.run("SELECT label, grams FROM portions WHERE food_id = ?", [id])) ?? []).compactMap { r in
            guard let l = r["label"]?.string, let g = r["grams"]?.double else { return nil }
            return Food.Portion(label: l, grams: g)
        }
    }

    /// Foods whose description has all the words (else any of them), best first; raw and plain ones win over prepared dishes.
    public func search(_ query: String, limit: Int = 10) -> [Food] {
        let words = query.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        func run(_ words: [String], _ joiner: String) -> [Food] {
            let q = words.map { "\"\($0)\"*" }.joined(separator: joiner)
            // The main noun comes first in USDA names ("Milk, whole" rather than "Yogurt, whole milk").
            let rows = (try? db.run("""
                SELECT f.* FROM foods_fts t JOIN foods f ON f.id = t.rowid WHERE foods_fts MATCH ?
                ORDER BY bm25(foods_fts) + length(f.name) / 60.0 - (CASE WHEN f.name LIKE '%raw%' THEN 0.5 ELSE 0 END)
                       - (CASE WHEN f.source = 'foundation' THEN 0.3 ELSE 0 END)
                       - (CASE WHEN f.name LIKE ? THEN 2.0 ELSE 0 END) LIMIT ?
                """, [q, words[0] + "%", limit])) ?? []
            return rows.map(food)
        }
        // All words first, then fewer and fewer from the end ("milk whole fluid" → "milk whole" → "milk").
        var hits: [Food] = []
        for n in stride(from: words.count, through: 1, by: -1) where hits.count < limit {
            hits += run(Array(words.prefix(n)), " AND ").filter { h in !hits.contains { $0.id == h.id } }.prefix(n == words.count ? limit : max(3, limit / 3))
        }
        if hits.count < 3 { hits += run(words, " OR ").filter { h in !hits.contains { $0.id == h.id } } }
        return Array(hits.prefix(limit)).map { var f = $0; f.portions = portions(Int64($0.id.dropFirst(5)) ?? 0); return f }
    }
}

/// Open Food Facts (world.openfoodfacts.org): packaged products by name or barcode, also Slovak and Czech ones.
public enum OpenFoodFacts {
    static let agent = "Recepty/0.1 (macOS recipe app)"

    static func get(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ReceptyError("Open Food Facts neodpovedá.") }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func food(_ p: [String: Any]) -> Food? {
        guard let code = p["code"] as? String, let n = p["nutriments"] as? [String: Any] else { return nil }
        func v(_ k: String) -> Double? { (n["\(k)_100g"] as? NSNumber)?.doubleValue ?? (n["\(k)_100g"] as? String).flatMap(Double.init) }
        guard let kcal = v("energy-kcal") ?? v("energy").map({ $0 / 4.184 }) else { return nil }
        let name = (p["product_name_sk"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (p["product_name"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let per = Nutrients(kcal: kcal, protein: v("proteins") ?? 0, fat: v("fat") ?? 0, carbs: v("carbohydrates") ?? 0, fiber: v("fiber") ?? 0,
                            sugars: v("sugars") ?? 0, satFat: v("saturated-fat") ?? 0, salt: v("salt") ?? (v("sodium").map { $0 * 2.5 } ?? 0))
        var f = Food(id: "off:\(code)", name: name, brand: (p["brands"] as? String)?.components(separatedBy: ",").first ?? "", per100: per)
        if let q = (p["serving_quantity"] as? NSNumber)?.doubleValue, q > 0 { f.portions = [.init(label: (p["serving_size"] as? String) ?? "1 porcia", grams: q)] }
        return f
    }

    static let fields = "code,product_name,product_name_sk,brands,nutriments,serving_size,serving_quantity"

    public static func search(_ query: String, limit: Int = 8) async throws -> [Food] {
        var c = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        c.queryItems = [.init(name: "search_terms", value: query), .init(name: "search_simple", value: "1"), .init(name: "json", value: "1"),
                        .init(name: "page_size", value: "\(limit * 2)"), .init(name: "fields", value: fields)]
        let j = try await get(c.url!)
        return ((j["products"] as? [[String: Any]]) ?? []).compactMap(food).prefix(limit).map { $0 }
    }

    public static func product(_ barcode: String) async throws -> Food? {
        let code = barcode.filter(\.isNumber)
        guard !code.isEmpty, let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=\(fields)") else { return nil }
        let j = try await get(url)
        return (j["product"] as? [String: Any]).flatMap(food)
    }
}

public extension Food {
    /// Looks a reference up again ("usda:…" in the bundled database, "off:…" online).
    static func lookup(_ ref: String) async -> Food? {
        if ref.hasPrefix("usda:") { return FoodDB.shared?.food(ref) }
        if ref.hasPrefix("off:") { return try? await OpenFoodFacts.product(String(ref.dropFirst(4))) }
        return nil
    }
}
