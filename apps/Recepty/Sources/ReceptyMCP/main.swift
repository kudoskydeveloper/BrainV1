import Foundation
import ReceptyCore

// recepty-mcp: stdio MCP server (JSON-RPC, one message per line) over the Recepty database. Works while the app is closed;
// the app picks up changes by itself. Writes are plain MCP write tools, so Brain shows them as proposals for the user's yes.

setvbuf(stdout, nil, _IOLBF, 0)
let store: Store
do { store = try Store() } catch {
    FileHandle.standardError.write(Data("recepty-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}

struct ToolError: Error { let message: String; init(_ m: String) { message = m } }

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write(Data([0x0A]))
}

/// Runs async work from the synchronous request loop.
final class Box<T>: @unchecked Sendable { var value: Result<T, Error>? }
func wait<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<T>(), sem = DispatchSemaphore(value: 0)
    Task.detached { do { box.value = .success(try await body()) } catch { box.value = .failure(error) }; sem.signal() }
    sem.wait()
    return try box.value!.get()
}

func str(_ a: [String: Any], _ k: String) -> String? {
    if let s = a[k] as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
    if let n = a[k] as? NSNumber { return n.stringValue }
    return nil
}
func dbl(_ a: [String: Any], _ k: String) -> Double? {
    if let n = a[k] as? NSNumber { return n.doubleValue }
    return (a[k] as? String).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
}
func date(_ a: [String: Any], _ k: String) throws -> String? {
    guard let s = str(a, k) else { return nil }
    switch fold(s) {
    case "dnes", "today": return Day.today
    case "vcera", "yesterday": return Day.adding(-1, to: Day.today)
    case "zajtra", "tomorrow": return Day.adding(1, to: Day.today)
    default:
        guard Day.date(s) != nil, s.count == 10 else { throw ToolError("\(k) musí byť RRRR-MM-DD.") }
        return s
    }
}

// MARK: JSON shapes

func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

func summaryJSON(_ r: Recipe) -> [String: Any] {
    var d: [String: Any] = ["id": r.id, "title": r.title, "servings": r.servings, "tags": r.tags, "favorite": r.favorite,
                            "ingredients": r.ingredients.count, "cooked": r.cookedCount]
    if let t = r.totalMin { d["total_min"] = t }
    if !r.author.isEmpty { d["author"] = r.author }
    if !r.photos.isEmpty { d["original_photos"] = r.photos.count }
    if !r.needsAnalysis, !r.ingredients.isEmpty { d["kcal_per_serving"] = r.perServing.kcal.rounded(); d["protein_per_serving_g"] = r1(r.perServing.protein) }
    else { d["analysed"] = false }
    if let l = r.lastCooked { d["last_eaten"] = l }
    return d
}

func detailJSON(_ r: Recipe, servings: Double? = nil) -> [String: Any] {
    let s = servings ?? r.servings, k = s / max(r.servings, 0.01)
    var d = summaryJSON(r)
    d["servings"] = s
    if servings != nil { d["recipe_servings"] = r.servings }
    d["ingredients"] = r.ingredients.map { i -> [String: Any] in
        var x: [String: Any] = ["line": i.scaledLine(k), "status": i.status.rawValue]
        if !i.section.isEmpty { x["section"] = i.section }
        if let g = i.scaledGrams(k) { x["grams"] = r1(g) }
        if let f = i.foodName { x["food"] = f }
        if let n = i.nutrients { x["kcal"] = (n.kcal * k).rounded() }
        return x
    }
    d["steps"] = r.steps
    d["nutrition"] = ["per_serving": r.perServing.json, "per_100g": r.per100.json, "whole_recipe": (r.total * k).json,
                      "grams_per_serving": r.gramsPerServing.rounded(), "dish_grams": (r.dishGrams * k).rounded(),
                      "dish_weighed": r.yieldGrams != nil] as [String: Any]
    let open = r.unresolved.map(\.line)
    if !open.isEmpty { d["not_counted"] = open }
    if r.hasEstimates { d["has_estimates"] = true }
    if !r.notes.isEmpty { d["notes"] = r.notes }
    if !r.sourceURL.isEmpty { d["source_url"] = r.sourceURL }
    if let p = r.prepMin { d["prep_min"] = p }
    if let c = r.cookMin { d["cook_min"] = c }
    if let y = r.yieldGrams { d["yield_grams"] = y }
    if !r.photos.isEmpty {
        d["original_photos"] = r.photos.map { p -> [String: Any] in
            var x: [String: Any] = ["path": p.path]
            if !p.text.isEmpty { x["text"] = p.text }
            return x
        }
    }
    d["link"] = "recepty://recipe/\(r.id)"
    return d
}

func mealJSON(_ m: Meal) -> [String: Any] {
    var d: [String: Any] = ["id": m.id, "date": m.date, "slot": m.slot.rawValue, "title": m.title, "nutrients": m.nutrients.json]
    if let r = m.recipeId { d["recipe_id"] = r }
    if let g = m.grams { d["grams"] = g.rounded() }
    if let s = m.servings { d["servings"] = r1(s) }
    return d
}

func planJSON(_ p: PlanItem) -> [String: Any] {
    var d: [String: Any] = ["id": p.id, "date": p.date, "slot": p.slot.rawValue, "recipe_id": p.recipeId, "title": p.title, "servings": p.servings]
    if !p.note.isEmpty { d["note"] = p.note }
    return d
}

func find(_ a: [String: Any]) throws -> Recipe {
    do { return try store.findRecipe(a["recipe"] ?? a["id"]) } catch { throw ToolError("\(error.localizedDescription)") }
}

// MARK: Tools

func prop(_ type: String, _ desc: String) -> [String: Any] { ["type": type, "description": desc] }
let recipeArg = prop("string", "Recipe id or (part of) its title.")
let dateArg = prop("string", "YYYY-MM-DD, or dnes / včera / zajtra.")
let slotArg: [String: Any] = ["type": "string", "enum": MealSlot.allCases.map(\.rawValue), "description": "Meal of the day."]

func tool(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = [], write: Bool = false) -> [String: Any] {
    ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any],
     "annotations": ["readOnlyHint": !write, "destructiveHint": false] as [String: Any]]
}

let tools: [[String: Any]] = [
    tool("recipes", "The user's recipes (newest first): id, title, servings, kcal and protein per serving, tags, time, how often eaten. Filter by words, tag or favorites.",
         ["query": prop("string", "Words in the title, a tag, who it's from or an ingredient."), "tag": prop("string", "Only with this tag."),
          "author": prop("string", "Only recipes from this person (e.g. 'babka'), part of the name is enough."), "favorite": prop("boolean", "Only favorites.")]),
    tool("recipe", "One recipe: ingredient lines (scaled to `servings` when given) with grams, steps, nutrition per serving / per 100 g / whole dish, what isn't counted.",
         ["recipe": recipeArg, "servings": prop("number", "Scale to this many servings (portion calculator).")], required: ["recipe"]),
    tool("recipe_import", "Saves a new recipe from a web page (url), from photos (images: files, e.g. from Brain photos_export or a chat attachment; a cookbook page, a recipe card; read with OCR) or from any text, in Slovak, and analyses its nutrition (USDA + Open Food Facts, through the model). Takes up to a minute.",
         ["url": prop("string", "Recipe page."), "text": prop("string", "Recipe as text."),
          "images": ["type": "array", "items": ["type": "string"], "description": "Paths of photos or scanned PDFs of one recipe, in page order."] as [String: Any], "author": prop("string", "Who the recipe is from (e.g. 'babka Mária'); from photos it's also read from the original when it says so."),
          "analyze": prop("boolean", "Analyse nutrition right away (default true).")], write: true),
    tool("recipe_update", "Changes a recipe. ingredients (one line per item, '# Section' lines for groups) replaces the list; lines that stay the same keep their analysis, new ones are analysed.",
         ["recipe": recipeArg, "title": prop("string", ""), "servings": prop("number", ""), "yield_grams": prop("number", "Weight of the finished dish in grams (weighed), for exact portions by grams."),
          "prep_min": prop("integer", ""), "cook_min": prop("integer", ""), "tags": ["type": "array", "items": ["type": "string"]] as [String: Any],
          "notes": prop("string", ""), "favorite": prop("boolean", ""), "author": prop("string", "Who the recipe is from; empty string removes it."),
          "add_photos": ["type": "array", "items": ["type": "string"], "description": "Paths of photos of the original to keep with the recipe (archive)."] as [String: Any], "ingredients": prop("string", "All ingredient lines, one per line."),
          "steps": ["type": "array", "items": ["type": "string"], "description": "All steps in order."] as [String: Any]], required: ["recipe"], write: true),
    tool("recipe_analyze", "Analyses nutrition of the lines not analysed yet (all = again for every line except hand-fixed ones).",
         ["recipe": recipeArg, "all": prop("boolean", "")], required: ["recipe"], write: true),
    tool("recipe_delete", "Deletes a recipe (its meal log entries stay, without the link).", ["recipe": recipeArg], required: ["recipe"], write: true),
    tool("food_search", "Foods with nutrients per 100 g: the bundled USDA database (English names) and Open Food Facts (packaged products, also Slovak), or one product by barcode.",
         ["query": prop("string", "Food name (English works best for USDA) or a barcode.")], required: ["query"]),
    tool("meal_log", "Logs what the user ate: a portion of a recipe (grams of the finished dish, or servings), or a free entry with its nutrients.",
         ["recipe": recipeArg, "grams": prop("number", "Grams eaten of the finished dish."), "servings": prop("number", "Servings eaten (default 1)."),
          "title": prop("string", "Free entry without a recipe."), "kcal": prop("number", "Free entry."), "protein": prop("number", "Free entry, g."),
          "fat": prop("number", "Free entry, g."), "carbs": prop("number", "Free entry, g."), "date": dateArg, "slot": slotArg], write: true),
    tool("meals", "The meal log by day with totals (kcal, protein, fat, carbs). Default today.", ["date": dateArg, "from": dateArg, "to": dateArg]),
    tool("meal_delete", "Removes a meal log entry.", ["id": prop("integer", "")], required: ["id"], write: true),
    tool("plan", "The meal plan (default this week, Monday to Sunday).", ["from": dateArg, "to": dateArg]),
    tool("plan_add", "Plans a recipe for a day.", ["recipe": recipeArg, "date": dateArg, "slot": slotArg, "servings": prop("number", "Default the recipe's servings."),
                                                  "note": prop("string", "")], required: ["recipe", "date"], write: true),
    tool("plan_remove", "Removes a planned recipe.", ["id": prop("integer", "")], required: ["id"], write: true),
    tool("shopping_list", "What to buy for the planned recipes in a period (default from today to Sunday), the same food added up. Brain's shopping_add can put it on the list.",
         ["from": dateArg, "to": dateArg, "recipe": prop("string", "Instead of the plan: one recipe (with servings)."), "servings": prop("number", "")]),
]

func call(_ name: String, _ a: [String: Any]) throws -> Any {
    switch name {
    case "recipes":
        var all = store.recipes()
        if a["favorite"] as? Bool == true { all = all.filter(\.favorite) }
        if let t = str(a, "tag") { all = all.filter { $0.tags.contains { fold($0) == fold(t) } } }
        if let w = str(a, "author") { all = all.filter { fold($0.author).contains(fold(w)) } }
        if let q = str(a, "query") {
            let words = fold(q).split(separator: " ").map(String.init)
            all = all.filter { r in
                let hay = fold(([r.title, r.author] + r.tags + r.ingredients.map(\.line)).joined(separator: " "))
                return words.allSatisfy { hay.contains($0) }
            }
        }
        return ["count": all.count, "recipes": all.map(summaryJSON)]
    case "recipe":
        return detailJSON(try find(a), servings: dbl(a, "servings"))
    case "recipe_import":
        let url = str(a, "url"), txt = str(a, "text")
        let images = ((a["images"] as? [Any]) ?? []).compactMap { $0 as? String }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        guard url != nil || txt != nil || !images.isEmpty else { throw ToolError("Zadaj url, images alebo text.") }
        if let missing = images.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) { throw ToolError("Súbor neexistuje: \(missing.path)") }
        var r = try wait {
            let imp = Importer(store: store)
            if !images.isEmpty { return try await imp.fromImages(images) }
            return url != nil ? try await imp.fromURL(url!) : try await imp.fromText(txt!)
        }
        if let w = str(a, "author") { r.author = w }
        r = try store.save(r)
        var analysisError: String?
        if a["analyze"] as? Bool != false {
            let saved = r
            do { r = try wait { try await Analyzer(store: store).analyze(saved) } } catch { analysisError = error.localizedDescription }
        }
        var d = detailJSON(r)
        if let e = analysisError { d["analysis_error"] = e }
        return d
    case "recipe_update":
        var r = try find(a)
        if let s = str(a, "title") { r.title = s }
        if let s = dbl(a, "servings"), s > 0 { r.servings = s }
        if a.keys.contains("yield_grams") { r.yieldGrams = dbl(a, "yield_grams").flatMap { $0 > 0 ? $0 : nil } }
        if a.keys.contains("prep_min") { r.prepMin = dbl(a, "prep_min").map { Int($0) } }
        if a.keys.contains("cook_min") { r.cookMin = dbl(a, "cook_min").map { Int($0) } }
        if let t = a["tags"] as? [Any] { r.tags = t.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let n = a["notes"] as? String { r.notes = n }
        if let f = a["favorite"] as? Bool { r.favorite = f }
        if let w = a["author"] as? String { r.author = w.trimmingCharacters(in: .whitespaces) }
        for path in ((a["add_photos"] as? [Any]) ?? []).compactMap({ $0 as? String }) {
            let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: u.path) else { throw ToolError("Súbor neexistuje: \(u.path)") }
            let t = (try? wait { try await Importer.ocr(u) }) ?? ""
            r.photos.append(SourcePhoto(path: u.path, text: t.replacingOccurrences(of: #"^\[image[^\]]*\]\s*"#, with: "", options: .regularExpression)))
        }
        if let s = a["steps"] as? [Any] { r.steps = s.compactMap { $0 as? String }.filter { !$0.isEmpty } }
        if let t = a["ingredients"] as? String { r.ingredients = Recipe.ingredients(fromText: t, keeping: r.ingredients) }
        r = try store.save(r)
        if r.needsAnalysis {
            let saved = r
            r = (try? wait { try await Analyzer(store: store).analyze(saved) }) ?? r
        }
        return detailJSON(r)
    case "recipe_analyze":
        let r = try find(a), all = a["all"] as? Bool == true
        return detailJSON(try wait { try await Analyzer(store: store).analyze(r, all: all) })
    case "recipe_delete":
        let r = try find(a)
        try store.delete(recipe: r.id)
        return ["deleted": true, "id": r.id, "title": r.title]
    case "food_search":
        guard let q = str(a, "query") else { throw ToolError("Chýba query.") }
        let foods: [Food] = try wait {
            if q.allSatisfy(\.isNumber), q.count >= 8 { return (try await OpenFoodFacts.product(q)).map { [$0] } ?? [] }
            return await Analyzer.candidates(q)
        }
        return foods.map { f -> [String: Any] in
            ["ref": f.id, "name": f.displayName, "source": f.source, "per_100g": f.per100.json,
             "portions": f.portions.prefix(5).map { "\($0.label) = \($0.grams) g" }]
        }
    case "meal_log":
        let slot = MealSlot.parse(str(a, "slot")) ?? defaultSlot()
        let day = try date(a, "date") ?? Day.today
        if a["recipe"] != nil {
            let r = try find(a)
            guard !r.needsAnalysis else { throw ToolError("Recept „\(r.title)“ ešte nie je zanalyzovaný (recipe_analyze).") }
            return mealJSON(try store.logMeal(recipe: r, grams: dbl(a, "grams"), servings: dbl(a, "servings"), date: day, slot: slot))
        }
        guard let t = str(a, "title") else { throw ToolError("Zadaj recipe alebo title s nutrientmi.") }
        var m = Meal()
        m.date = day; m.slot = slot; m.title = t; m.grams = dbl(a, "grams")
        m.nutrients = Nutrients(kcal: dbl(a, "kcal") ?? 0, protein: dbl(a, "protein") ?? 0, fat: dbl(a, "fat") ?? 0, carbs: dbl(a, "carbs") ?? 0)
        return mealJSON(try store.save(m))
    case "meals":
        let from = try date(a, "from") ?? date(a, "date") ?? Day.today
        let to = try date(a, "to") ?? date(a, "date") ?? from
        let list = store.meals(from: from, to: to)
        let days = Dictionary(grouping: list, by: \.date).sorted { $0.key < $1.key }.map { d, ms -> [String: Any] in
            ["date": d, "total": ms.map(\.nutrients).reduce(.zero, +).json, "meals": ms.map(mealJSON)]
        }
        return ["from": from, "to": to, "days": days]
    case "meal_delete":
        guard let id = (a["id"] as? NSNumber)?.int64Value else { throw ToolError("Chýba id.") }
        try store.deleteMeal(id)
        return ["deleted": true, "id": id]
    case "plan":
        let from = try date(a, "from") ?? Day.weekStart(Day.today)
        let to = try date(a, "to") ?? Day.adding(6, to: from)
        return ["from": from, "to": to, "items": store.plan(from: from, to: to).map(planJSON)]
    case "plan_add":
        let r = try find(a)
        guard let day = try date(a, "date") else { throw ToolError("Chýba date.") }
        var p = PlanItem()
        p.date = day; p.recipeId = r.id; p.slot = MealSlot.parse(str(a, "slot")) ?? .lunch
        p.servings = dbl(a, "servings") ?? r.servings; p.note = str(a, "note") ?? ""
        return planJSON(try store.save(p))
    case "plan_remove":
        guard let id = (a["id"] as? NSNumber)?.int64Value else { throw ToolError("Chýba id.") }
        try store.deletePlan(id)
        return ["deleted": true, "id": id]
    case "shopping_list":
        var pairs: [(Recipe, Double)] = []
        var from = "", to = ""
        if a["recipe"] != nil {
            let r = try find(a); pairs = [(r, dbl(a, "servings") ?? r.servings)]
        } else {
            from = try date(a, "from") ?? Day.today
            to = try date(a, "to") ?? Day.adding(6, to: Day.weekStart(Day.today))
            for p in store.plan(from: from, to: to) { if let r = store.recipe(p.recipeId) { pairs.append((r, p.servings)) } }
        }
        let items = Shopping.list(pairs)
        var d: [String: Any] = ["recipes": pairs.map { "\($0.0.title) (\(Fmt.number($0.1)) porc.)" },
                                "items": items.map { ["item": $0.label, "name": $0.name, "for": $0.recipes] as [String: Any] }]
        if !from.isEmpty { d["from"] = from; d["to"] = to }
        return d
    default:
        throw ToolError("Neznámy nástroj \(name).")
    }
}

func defaultSlot() -> MealSlot {
    let h = Calendar.current.component(.hour, from: Date())
    return h < 10 ? .breakfast : h < 15 ? .lunch : h < 17 ? .snack : .dinner
}

let instructions = """
Recepty sú lokálna appka používateľa na recepty (v Hangar). recipes hľadá recepty, recipe ukáže suroviny, postup a výživové hodnoty \
(na porciu, na 100 g, celé jedlo); s servings prepočíta suroviny na iný počet porcií. Nový recept z odkazu, fotky (images: cesty, napr. z Brain photos_export; fotky sa archivujú pri recepte ako originál, model prečíta aj rukopis) alebo textu: recipe_import; author = od koho recept je (babka…), recipes s author ich vyfiltruje \
(uloží v slovenčine a spočíta výživu z USDA a Open Food Facts). Čo používateľ zjedol: meal_log (recept a gramy alebo porcie; gramy sú \
presné, keď má recept zadanú hmotnosť hotového jedla yield_grams). Jedálniček: plan, plan_add; nákup: shopping_list (potom Brain shopping_add). \
Odkaz recepty://recipe/<id> otvorí recept v appke.
"""

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
    guard let id = msg["id"] else { continue }
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "recepty", "version": "0.1"],
            "instructions": instructions,
        ] as [String: Any]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let result = try call(name, args)
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])) ?? Data()
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]])
        } catch {
            let text = (error as? ToolError)?.message ?? error.localizedDescription
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": true]])
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}
