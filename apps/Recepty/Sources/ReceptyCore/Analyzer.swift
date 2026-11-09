import Foundation

/// Nutrition analysis of a recipe in two model calls:
/// 1. every pending line → food name, amount, weight in grams and an English search query;
/// 2. per line, the model picks the right food among candidates from the bundled USDA database and Open Food Facts
///    (or estimates per 100 g when none fits).
/// A food the user picked by hand once (Store.remember) is used directly, without asking the model.
public final class Analyzer {
    let store: Store
    public init(store: Store) { self.store = store }

    static let parseSystem = """
    You read ingredient lines of a recipe (often Slovak or Czech) and return ONLY a JSON object, no prose:
    {"items":[{"i":<index>,"name":"<the food in Slovak, nominative singular, without amount, e.g. 'hladká múka', 'vajce', 'olivový olej'>",
    "qty":<number or null>,"unit":"<g|kg|ml|l|ks|PL|ČL|hrnček|štipka|strúčik|plátok|balenie|konzerva|hrsť|zväzok|'' >",
    "grams":<best estimate of the weight in grams of this line for the whole recipe, number or null>,
    "query":"<English search query in USDA FoodData Central style, main noun first, e.g. 'flour wheat all-purpose', 'egg whole raw', 'oil olive', 'cheese cottage lowfat'>",
    "branded":<true when it is a specific packaged product or brand>,"skip":<true only for things with no nutrition worth counting: water, ice, salt/pepper 'to taste' without amount, optional garnish>}]}
    Rules: 1 PL (polievková lyžica) ≈ 15 ml, 1 ČL (čajová lyžička) ≈ 5 ml, hrnček ≈ 250 ml; convert ml to grams with the food's density
    (oil 0.92, flour ~0.55 g/ml, sugar 0.85, milk 1.03). Eggs: 1 ks ≈ 55 g without shell. "1 cibuľa" ≈ 110 g, "1 strúčik cesnaku" ≈ 5 g.
    For ranges ("2-3") use the middle. Weight is of the edible part as used (raw unless the line says cooked).
    """

    static let pickSystem = """
    You match recipe ingredients to food database entries. Return ONLY a JSON object, no prose:
    {"items":[{"i":<index>,"ref":"<chosen candidate ref, or null when no candidate is the same food>","grams":<corrected grams for the whole line, number>,
    "estimate":<only when ref is null: per 100 g {"kcal":n,"protein":n,"fat":n,"carbs":n,"fiber":n,"sugars":n,"sat_fat":n,"salt":n}>}]}
    Prefer the raw / plain form unless the line says otherwise (cooked rice, canned beans drained, etc.). Fat level and type matter
    (Slovak 'polotučné mlieko' = 1.5 % milk, 'plnotučné' = 3.5 %, 'tvaroh' = quark/cottage cheese, 'smotana na šľahanie' = heavy cream 33 %,
    'kyslá smotana' = sour cream). A Slovak/Czech packaged product: prefer its Open Food Facts candidate ('off:…').
    Use a candidate's portions to correct grams when the line counts pieces. Estimates are typical values per 100 g of the food as used.
    """

    /// Analyses the pending lines (or all but the hand-fixed ones when `all`), saves the recipe and returns it.
    @discardableResult
    public func analyze(_ recipe: Recipe, all: Bool = false, progress: (@Sendable (String) -> Void)? = nil) async throws -> Recipe {
        var r = recipe
        let todo = r.ingredients.indices.filter { all ? r.ingredients[$0].status != .manual : r.ingredients[$0].status == .pending }
        guard !todo.isEmpty else { return r }

        progress?("Čítam suroviny…")
        let lines: [[String: Any]] = todo.map { ["i": $0, "line": r.ingredients[$0].line, "section": r.ingredients[$0].section] }
        let parsed = try await AI.json(system: Self.parseSystem, input: ["recipe": r.title, "servings": r.servings, "lines": lines], store: store)
        var info: [Int: [String: Any]] = [:]
        for it in (parsed["items"] as? [[String: Any]]) ?? [] { if let i = (it["i"] as? NSNumber)?.intValue { info[i] = it } }

        progress?("Hľadám potraviny v databáze…")
        var ask: [[String: Any]] = []
        var candidates: [Int: [Food]] = [:]
        for i in todo {
            var ing = r.ingredients[i]
            guard let it = info[i] else { ing.status = .failed; r.ingredients[i] = ing; continue }
            ing.name = text(it["name"]).isEmpty ? ing.line : text(it["name"])
            ing.qty = num(it["qty"])
            ing.unit = text(it["unit"])
            ing.grams = Self.exactGrams(qty: ing.qty, unit: ing.unit) ?? num(it["grams"])
            if it["skip"] as? Bool == true {
                ing.status = .skipped; ing.foodRef = nil; ing.foodName = nil; ing.per100 = nil
                r.ingredients[i] = ing; continue
            }
            if let a = store.alias(ing.name) {
                ing.foodRef = a.foodRef; ing.foodName = a.foodName; ing.per100 = a.per100; ing.status = .matched
                if let q = ing.qty, let g = a.unitGrams[fold(ing.unit)] { ing.grams = q * g }
                r.ingredients[i] = ing
                if ing.grams != nil { continue }
            }
            r.ingredients[i] = ing
            var c = FoodDB.shared?.search(text(it["query"]).isEmpty ? ing.name : text(it["query"]), limit: 10) ?? []
            if it["branded"] as? Bool == true || c.isEmpty {
                c += ((try? await OpenFoodFacts.search(ing.name, limit: 4)) ?? [])
            }
            candidates[i] = c
            ask.append(["i": i, "line": ing.line, "name": ing.name, "grams": ing.grams as Any,
                        "candidates": c.map { f in
                            ["ref": f.id, "name": f.displayName, "kcal": f.per100.kcal.rounded(), "protein": f.per100.protein.rounded(),
                             "fat": f.per100.fat.rounded(), "carbs": f.per100.carbs.rounded(),
                             "portions": f.portions.prefix(4).map { "\($0.label) = \($0.grams) g" }] as [String: Any]
                        }])
        }

        if !ask.isEmpty {
            progress?("Vyberám najlepšie zhody…")
            let picked = try await AI.json(system: Self.pickSystem, input: ["recipe": r.title, "items": ask], store: store)
            for it in (picked["items"] as? [[String: Any]]) ?? [] {
                guard let i = (it["i"] as? NSNumber)?.intValue, r.ingredients.indices.contains(i) else { continue }
                var ing = r.ingredients[i]
                if let g = num(it["grams"]), g >= 0, Self.exactGrams(qty: ing.qty, unit: ing.unit) == nil { ing.grams = g }
                let ref = text(it["ref"])
                if ing.status == .matched, ing.per100 != nil {
                    // remembered food, the model only supplied the weight
                } else if !ref.isEmpty, let f = candidates[i]?.first(where: { $0.id == ref }) {
                    ing.foodRef = f.id; ing.foodName = f.displayName; ing.per100 = f.per100; ing.status = .matched
                } else if let e = it["estimate"] as? [String: Any], let kcal = num(e["kcal"]) {
                    ing.foodRef = "ai"; ing.foodName = "Odhad"; ing.status = .estimated
                    ing.per100 = Nutrients(kcal: kcal, protein: num(e["protein"]) ?? 0, fat: num(e["fat"]) ?? 0, carbs: num(e["carbs"]) ?? 0,
                                           fiber: num(e["fiber"]) ?? 0, sugars: num(e["sugars"]) ?? 0, satFat: num(e["sat_fat"]) ?? 0, salt: num(e["salt"]) ?? 0)
                } else {
                    ing.status = .failed
                }
                r.ingredients[i] = ing
            }
        }
        for i in todo where r.ingredients[i].status == .pending { r.ingredients[i].status = .failed }
        progress?("Ukladám…")
        return try store.save(r)
    }

    /// Weight the unit states by itself (g, kg, dkg).
    public static func exactGrams(qty: Double?, unit: String) -> Double? {
        guard let q = qty else { return nil }
        switch fold(unit) {
        case "g", "gr", "gram", "gramov": return q
        case "dkg", "dag": return q * 10
        case "kg": return q * 1000
        default: return nil
        }
    }

    /// Sets a food the user picked by hand on a line and remembers it for the same name next time.
    public func use(_ food: Food, for ing: inout Ingredient, grams: Double?) throws {
        ing.foodRef = food.id; ing.foodName = food.displayName; ing.per100 = food.per100; ing.status = .manual
        if let g = grams { ing.grams = g }
        let unitGrams: Double? = (ing.qty ?? 0) > 0 && ing.grams != nil && Self.exactGrams(qty: ing.qty, unit: ing.unit) == nil ? ing.grams! / ing.qty! : nil
        try store.remember(ing.name.isEmpty ? ing.line : ing.name, ref: food.id, foodName: food.displayName, per100: food.per100,
                           unit: ing.unit, unitGrams: unitGrams)
    }

    /// Candidates for a line the user is fixing: the bundled database by an English query, Open Food Facts by the name.
    /// A Slovak name ("polotučné mlieko") is translated to an English query first when the bundled database finds little.
    public static func candidates(_ query: String, store: Store? = nil) async -> [Food] {
        async let off = (try? OpenFoodFacts.search(query, limit: 6)) ?? []
        var usda = FoodDB.shared?.search(query, limit: 12) ?? []
        if usda.count < 4, AI.available,
           let o = try? await AI.json(system: querySystem, input: ["name": query], store: store), case let q = text(o["query"]), !q.isEmpty {
            usda = (FoodDB.shared?.search(q, limit: 12) ?? []) + usda.filter { u in !(FoodDB.shared?.search(q, limit: 12) ?? []).contains { $0.id == u.id } }
        }
        return usda + (await off)
    }

    static let querySystem = """
    Translate the food name (usually Slovak or Czech) into an English search query in USDA FoodData Central style, main noun first
    (e.g. 'polotučné mlieko' → 'milk reduced fat 2%', 'tvaroh' → 'cheese cottage', 'hladká múka' → 'flour wheat all-purpose').
    Return ONLY {"query":"…"}.
    """
}
