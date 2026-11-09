import Foundation

/// The recipe database (~/Library/Application Support/Recepty/recepty.sqlite), shared by the app and recepty-mcp.
/// Recipes with their ingredients, the meal log, the meal plan and remembered food matches ("tvaroh" → the food the user
/// picked once), which the analysis uses before asking the model.
public final class Store {
    public let db: DB
    /// ~/Library/Application Support/Recepty, or the folder of RECEPTY_DB (demo and test runs keep their photos there too).
    public static var dir: URL {
        let d = ProcessInfo.processInfo.environment["RECEPTY_DB"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Recepty")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    public static var imagesDir: URL {
        let d = dir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Original photos of recipes, kept at full quality.
    public static var photosDir: URL {
        let d = dir.appendingPathComponent("originaly")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public init(path: String? = nil) throws {
        // RECEPTY_DB points the app and recepty-mcp at another database (demo and test runs).
        db = try DB(path: path ?? ProcessInfo.processInfo.environment["RECEPTY_DB"] ?? Self.dir.appendingPathComponent("recepty.sqlite").path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS recipes(
            id INTEGER PRIMARY KEY, title TEXT NOT NULL, servings REAL NOT NULL DEFAULT 4, yield_grams REAL,
            prep_min INTEGER, cook_min INTEGER, source_url TEXT NOT NULL DEFAULT '', image_path TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '[]', notes TEXT NOT NULL DEFAULT '', steps TEXT NOT NULL DEFAULT '[]',
            favorite INTEGER NOT NULL DEFAULT 0, created TEXT NOT NULL, updated TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS ingredients(
            id INTEGER PRIMARY KEY, recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE, pos INTEGER NOT NULL,
            line TEXT NOT NULL, section TEXT NOT NULL DEFAULT '', name TEXT NOT NULL DEFAULT '', qty REAL, unit TEXT NOT NULL DEFAULT '',
            grams REAL, food_ref TEXT, food_name TEXT, per100 TEXT, status TEXT NOT NULL DEFAULT 'pending', note TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS ingredients_recipe ON ingredients(recipe_id, pos);
        CREATE TABLE IF NOT EXISTS meals(
            id INTEGER PRIMARY KEY, date TEXT NOT NULL, slot TEXT NOT NULL, recipe_id INTEGER REFERENCES recipes(id) ON DELETE SET NULL,
            title TEXT NOT NULL, grams REAL, servings REAL, nutrients TEXT NOT NULL, created TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS meals_date ON meals(date);
        CREATE TABLE IF NOT EXISTS plan(
            id INTEGER PRIMARY KEY, date TEXT NOT NULL, slot TEXT NOT NULL, recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
            servings REAL NOT NULL DEFAULT 2, note TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS plan_date ON plan(date);
        CREATE TABLE IF NOT EXISTS food_aliases(
            key TEXT PRIMARY KEY, food_ref TEXT NOT NULL, food_name TEXT NOT NULL, per100 TEXT NOT NULL, unit_grams TEXT NOT NULL DEFAULT '{}', updated TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS ai_cache(key TEXT PRIMARY KEY, value TEXT NOT NULL, created TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS photos(
            id INTEGER PRIMARY KEY, recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE, pos INTEGER NOT NULL,
            path TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', added TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS photos_recipe ON photos(recipe_id, pos);
        """)
        // Columns added after the first version.
        let cols = Set(((try? db.run("PRAGMA table_info(recipes)")) ?? []).compactMap { $0["name"]?.string })
        if !cols.contains("author") { try db.exec("ALTER TABLE recipes ADD COLUMN author TEXT NOT NULL DEFAULT ''") }
    }

    /// Changes whenever any connection commits (the app polls it to pick up what recepty-mcp wrote).
    public var dataVersion: Int { (try? db.run("PRAGMA data_version").first?["data_version"]?.int) ?? 0 }

    // MARK: Recipes

    private static let enc = JSONEncoder()
    private static let dec = JSONDecoder()
    private func json<T: Encodable>(_ v: T) -> String { String(decoding: (try? Self.enc.encode(v)) ?? Data("null".utf8), as: UTF8.self) }
    private func decode<T: Decodable>(_ s: String?, _ t: T.Type) -> T? { s.flatMap { try? Self.dec.decode(T.self, from: Data($0.utf8)) } }

    private func photo(from r: Row) -> SourcePhoto {
        var p = SourcePhoto(path: r["path"]?.string ?? "", text: r["text"]?.string ?? "")
        p.id = r["id"]?.int64 ?? 0
        p.added = r["added"]?.string ?? ""
        return p
    }

    private func recipe(from r: Row, ingredients: [Ingredient], photos: [SourcePhoto] = []) -> Recipe {
        var x = Recipe(title: r["title"]?.string ?? "")
        x.id = r["id"]?.int64 ?? 0
        x.servings = r["servings"]?.double ?? 4
        x.yieldGrams = r["yield_grams"]?.double
        x.prepMin = r["prep_min"]?.int
        x.cookMin = r["cook_min"]?.int
        x.sourceURL = r["source_url"]?.string ?? ""
        x.imagePath = r["image_path"]?.string ?? ""
        x.tags = decode(r["tags"]?.string, [String].self) ?? []
        x.notes = r["notes"]?.string ?? ""
        x.author = r["author"]?.string ?? ""
        x.photos = photos
        x.steps = decode(r["steps"]?.string, [String].self) ?? []
        x.favorite = r["favorite"]?.int == 1
        x.created = r["created"]?.string ?? ""
        x.updated = r["updated"]?.string ?? ""
        x.cookedCount = r["cooked"]?.int ?? 0
        x.lastCooked = r["last_cooked"]?.string
        x.ingredients = ingredients
        return x
    }

    private func ingredient(from r: Row) -> Ingredient {
        var i = Ingredient(line: r["line"]?.string ?? "", section: r["section"]?.string ?? "")
        i.id = r["id"]?.int64 ?? 0
        i.pos = r["pos"]?.int ?? 0
        i.name = r["name"]?.string ?? ""
        i.qty = r["qty"]?.double
        i.unit = r["unit"]?.string ?? ""
        i.grams = r["grams"]?.double
        i.foodRef = r["food_ref"]?.string
        i.foodName = r["food_name"]?.string
        i.per100 = decode(r["per100"]?.string, Nutrients.self)
        i.status = MatchStatus(rawValue: r["status"]?.string ?? "") ?? .pending
        i.note = r["note"]?.string ?? ""
        return i
    }

    private let recipeSQL = """
        SELECT r.*, (SELECT COUNT(*) FROM meals m WHERE m.recipe_id = r.id) AS cooked,
               (SELECT MAX(date) FROM meals m WHERE m.recipe_id = r.id) AS last_cooked FROM recipes r
        """

    /// Every recipe with its ingredients, newest first.
    public func recipes() -> [Recipe] {
        let rows = (try? db.run(recipeSQL + " ORDER BY r.updated DESC")) ?? []
        var byRecipe: [Int64: [Ingredient]] = [:]
        for r in (try? db.run("SELECT * FROM ingredients ORDER BY recipe_id, pos")) ?? [] {
            byRecipe[r["recipe_id"]?.int64 ?? 0, default: []].append(ingredient(from: r))
        }
        var photosBy: [Int64: [SourcePhoto]] = [:]
        for r in (try? db.run("SELECT * FROM photos ORDER BY recipe_id, pos")) ?? [] {
            photosBy[r["recipe_id"]?.int64 ?? 0, default: []].append(photo(from: r))
        }
        return rows.map { let id = $0["id"]?.int64 ?? 0; return recipe(from: $0, ingredients: byRecipe[id] ?? [], photos: photosBy[id] ?? []) }
    }

    public func recipe(_ id: Int64) -> Recipe? {
        guard let r = try? db.run(recipeSQL + " WHERE r.id = ?", [id]).first else { return nil }
        let ings = ((try? db.run("SELECT * FROM ingredients WHERE recipe_id = ? ORDER BY pos", [id])) ?? []).map(ingredient(from:))
        let photos = ((try? db.run("SELECT * FROM photos WHERE recipe_id = ? ORDER BY pos", [id])) ?? []).map(photo(from:))
        return recipe(from: r, ingredients: ings, photos: photos)
    }

    /// By id, exact title, or the only title containing the words ("chilli" → "Chilli con carne").
    public func findRecipe(_ v: Any?) throws -> Recipe {
        if let n = v as? NSNumber, let r = recipe(n.int64Value) { return r }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { throw ReceptyError("Chýba recept (id alebo názov).") }
        if let id = Int64(s), let r = recipe(id) { return r }
        let all = recipes(), k = fold(s)
        if let r = all.first(where: { fold($0.title) == k }) { return r }
        let words = k.split(separator: " ").map(String.init)
        let hits = all.filter { r in words.allSatisfy { fold(r.title).contains($0) } }
        if hits.count == 1 { return hits[0] }
        throw ReceptyError(hits.isEmpty ? "Recept „\(s)“ neexistuje." : "Viac receptov pasuje na „\(s)“: \(hits.map { "\($0.title) (\($0.id))" }.joined(separator: ", ")).")
    }

    @discardableResult
    public func save(_ recipe: Recipe) throws -> Recipe {
        var r = recipe
        let now = Day.now
        if r.created.isEmpty { r.created = now }
        r.updated = now
        try db.transaction {
            let args: [Any?] = [r.title, r.servings, r.yieldGrams, r.prepMin, r.cookMin, r.sourceURL, r.imagePath, json(r.tags), r.notes,
                                json(r.steps), r.favorite, r.created, r.updated, r.author]
            if r.id == 0 {
                try db.run("""
                    INSERT INTO recipes(title, servings, yield_grams, prep_min, cook_min, source_url, image_path, tags, notes, steps, favorite, created, updated, author)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, args)
                r.id = db.lastID
            } else {
                try db.run("""
                    UPDATE recipes SET title=?, servings=?, yield_grams=?, prep_min=?, cook_min=?, source_url=?, image_path=?, tags=?, notes=?,
                    steps=?, favorite=?, created=?, updated=?, author=? WHERE id=?
                    """, args + [r.id])
                try db.run("DELETE FROM ingredients WHERE recipe_id = ?", [r.id])
            }
            for (n, i) in r.ingredients.enumerated() {
                r.ingredients[n].pos = n
                try db.run("""
                    INSERT INTO ingredients(recipe_id, pos, line, section, name, qty, unit, grams, food_ref, food_name, per100, status, note)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [r.id, n, i.line, i.section, i.name, i.qty, i.unit, i.grams, i.foodRef, i.foodName, i.per100.map(json), i.status.rawValue, i.note])
                r.ingredients[n].id = db.lastID
            }
            try addPhotos(r.photos.filter { $0.id == 0 }, to: r.id)
        }
        return self.recipe(r.id) ?? r
    }

    public func delete(recipe id: Int64) throws {
        if let r = recipe(id) {
            if !r.imagePath.isEmpty, r.imagePath.hasPrefix(Self.imagesDir.path) { try? FileManager.default.removeItem(atPath: r.imagePath) }
            for p in r.photos where p.path.hasPrefix(Self.photosDir.path) { try? FileManager.default.removeItem(atPath: p.path) }
        }
        try db.run("DELETE FROM recipes WHERE id = ?", [id])
    }

    /// Copies new photos of the original into the archive (full quality) and adds them after the recipe's other photos.
    public func addPhotos(_ photos: [SourcePhoto], to recipeId: Int64) throws {
        guard !photos.isEmpty else { return }
        var pos = (try db.run("SELECT COALESCE(MAX(pos), -1) + 1 AS n FROM photos WHERE recipe_id = ?", [recipeId]).first?["n"]?.int) ?? 0
        for p in photos {
            let src = URL(fileURLWithPath: p.path)
            let ext = src.pathExtension.isEmpty ? "jpg" : src.pathExtension.lowercased()
            let dest = Self.photosDir.appendingPathComponent("\(recipeId)-\(UUID().uuidString.prefix(8)).\(ext)")
            try FileManager.default.copyItem(at: src, to: dest)
            try db.run("INSERT INTO photos(recipe_id, pos, path, text, added) VALUES(?,?,?,?,?)", [recipeId, pos, dest.path, p.text, Day.now])
            pos += 1
        }
        try db.run("UPDATE recipes SET updated = ? WHERE id = ?", [Day.now, recipeId])
    }

    public func setPhotoText(_ id: Int64, _ text: String) throws { try db.run("UPDATE photos SET text = ? WHERE id = ?", [text, id]) }

    public func deletePhoto(_ id: Int64) throws {
        if let p = try db.run("SELECT path FROM photos WHERE id = ?", [id]).first?["path"]?.string, p.hasPrefix(Self.photosDir.path) {
            try? FileManager.default.removeItem(atPath: p)
        }
        try db.run("DELETE FROM photos WHERE id = ?", [id])
    }

    /// Who recipes are from, most recipes first.
    public func allAuthors() -> [String] {
        ((try? db.run("SELECT author, COUNT(*) AS n FROM recipes WHERE author != '' GROUP BY author ORDER BY n DESC, author")) ?? []).compactMap { $0["author"]?.string }
    }

    public func setFavorite(_ id: Int64, _ on: Bool) throws { try db.run("UPDATE recipes SET favorite = ? WHERE id = ?", [on, id]) }

    public func allTags() -> [String] {
        var count: [String: Int] = [:]
        for r in recipes() { for t in r.tags { count[t, default: 0] += 1 } }
        return count.keys.sorted { (count[$0]!, $1) > (count[$1]!, $0) }
    }

    // MARK: Remembered matches

    public struct Alias: Codable, Sendable {
        public var foodRef: String, foodName: String, per100: Nutrients
        /// Grams of one unit the user confirmed ("ks" → 60 for an egg).
        public var unitGrams: [String: Double]
    }

    public static func aliasKey(_ name: String) -> String {
        fold(name).replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    public func alias(_ name: String) -> Alias? {
        guard !name.isEmpty, let r = try? db.run("SELECT * FROM food_aliases WHERE key = ?", [Self.aliasKey(name)]).first,
              let p = decode(r["per100"]?.string, Nutrients.self) else { return nil }
        return Alias(foodRef: r["food_ref"]?.string ?? "", foodName: r["food_name"]?.string ?? "", per100: p,
                     unitGrams: decode(r["unit_grams"]?.string, [String: Double].self) ?? [:])
    }

    public func remember(_ name: String, ref: String, foodName: String, per100: Nutrients, unit: String? = nil, unitGrams: Double? = nil) throws {
        let key = Self.aliasKey(name)
        guard !key.isEmpty else { return }
        var units = alias(name).map(\.unitGrams) ?? [:]
        if let unit, !unit.isEmpty, let unitGrams, unitGrams > 0 { units[fold(unit)] = unitGrams }
        try db.run("INSERT OR REPLACE INTO food_aliases(key, food_ref, food_name, per100, unit_grams, updated) VALUES(?,?,?,?,?,?)",
                   [key, ref, foodName, json(per100), json(units), Day.now])
    }

    // MARK: Meal log

    private func meal(from r: Row) -> Meal {
        var m = Meal()
        m.id = r["id"]?.int64 ?? 0
        m.date = r["date"]?.string ?? ""
        m.slot = MealSlot(rawValue: r["slot"]?.string ?? "") ?? .lunch
        m.recipeId = r["recipe_id"]?.int64
        m.title = r["title"]?.string ?? ""
        m.grams = r["grams"]?.double
        m.servings = r["servings"]?.double
        m.nutrients = decode(r["nutrients"]?.string, Nutrients.self) ?? .zero
        m.created = r["created"]?.string ?? ""
        return m
    }

    public func meals(from: String, to: String) -> [Meal] {
        ((try? db.run("SELECT * FROM meals WHERE date BETWEEN ? AND ? ORDER BY date, CASE slot WHEN 'breakfast' THEN 0 WHEN 'snack' THEN 1 WHEN 'lunch' THEN 2 ELSE 3 END, id",
                      [from, to])) ?? []).map(meal(from:))
    }

    /// Logs a portion of a recipe: by grams of the finished dish (exact when the dish was weighed) or by servings.
    @discardableResult
    public func logMeal(recipe r: Recipe, grams: Double? = nil, servings: Double? = nil, date: String = Day.today, slot: MealSlot = .lunch) throws -> Meal {
        var m = Meal()
        m.date = date; m.slot = slot; m.recipeId = r.id; m.title = r.title
        if let g = grams, g > 0 {
            guard r.dishGrams > 0 else { throw ReceptyError("Recept nemá známu hmotnosť; zadaj porcie namiesto gramov.") }
            m.grams = g
            m.servings = g / r.gramsPerServing
            m.nutrients = r.total * (g / r.dishGrams)
        } else {
            let s = servings ?? 1
            m.servings = s
            m.grams = r.dishGrams > 0 ? r.gramsPerServing * s : nil
            m.nutrients = r.perServing * s
        }
        return try save(m)
    }

    @discardableResult
    public func save(_ meal: Meal) throws -> Meal {
        var m = meal
        if m.created.isEmpty { m.created = Day.now }
        if m.id == 0 {
            try db.run("INSERT INTO meals(date, slot, recipe_id, title, grams, servings, nutrients, created) VALUES(?,?,?,?,?,?,?,?)",
                       [m.date, m.slot.rawValue, m.recipeId, m.title, m.grams, m.servings, json(m.nutrients), m.created])
            m.id = db.lastID
        } else {
            try db.run("UPDATE meals SET date=?, slot=?, recipe_id=?, title=?, grams=?, servings=?, nutrients=? WHERE id=?",
                       [m.date, m.slot.rawValue, m.recipeId, m.title, m.grams, m.servings, json(m.nutrients), m.id])
        }
        return m
    }

    public func deleteMeal(_ id: Int64) throws { try db.run("DELETE FROM meals WHERE id = ?", [id]) }

    // MARK: Plan

    public func plan(from: String, to: String) -> [PlanItem] {
        ((try? db.run("SELECT p.*, r.title FROM plan p JOIN recipes r ON r.id = p.recipe_id WHERE p.date BETWEEN ? AND ? ORDER BY p.date, p.id",
                      [from, to])) ?? []).map { r in
            var p = PlanItem()
            p.id = r["id"]?.int64 ?? 0
            p.date = r["date"]?.string ?? ""
            p.slot = MealSlot(rawValue: r["slot"]?.string ?? "") ?? .lunch
            p.recipeId = r["recipe_id"]?.int64 ?? 0
            p.servings = r["servings"]?.double ?? 2
            p.title = r["title"]?.string ?? ""
            p.note = r["note"]?.string ?? ""
            return p
        }
    }

    @discardableResult
    public func save(_ item: PlanItem) throws -> PlanItem {
        var p = item
        if p.id == 0 {
            try db.run("INSERT INTO plan(date, slot, recipe_id, servings, note) VALUES(?,?,?,?,?)", [p.date, p.slot.rawValue, p.recipeId, p.servings, p.note])
            p.id = db.lastID
        } else {
            try db.run("UPDATE plan SET date=?, slot=?, recipe_id=?, servings=?, note=? WHERE id=?", [p.date, p.slot.rawValue, p.recipeId, p.servings, p.note, p.id])
        }
        return plan(from: p.date, to: p.date).first { $0.id == p.id } ?? p
    }

    public func deletePlan(_ id: Int64) throws { try db.run("DELETE FROM plan WHERE id = ?", [id]) }

    // MARK: Model answers cache

    public func cached(_ key: String) -> String? { try? db.run("SELECT value FROM ai_cache WHERE key = ?", [key]).first?["value"]?.string }
    public func cache(_ key: String, _ value: String) { _ = try? db.run("INSERT OR REPLACE INTO ai_cache VALUES(?,?,?)", [key, value, Day.now]) }
}
