import Foundation

/// Nutrients of an amount of food (or per 100 g, when it says so). kcal and grams; salt in grams.
public struct Nutrients: Codable, Equatable, Sendable {
    public var kcal = 0.0, protein = 0.0, fat = 0.0, carbs = 0.0
    public var fiber = 0.0, sugars = 0.0, satFat = 0.0, salt = 0.0

    public init(kcal: Double = 0, protein: Double = 0, fat: Double = 0, carbs: Double = 0,
                fiber: Double = 0, sugars: Double = 0, satFat: Double = 0, salt: Double = 0) {
        self.kcal = kcal; self.protein = protein; self.fat = fat; self.carbs = carbs
        self.fiber = fiber; self.sugars = sugars; self.satFat = satFat; self.salt = salt
    }

    public static let zero = Nutrients()
    public static func + (a: Nutrients, b: Nutrients) -> Nutrients {
        Nutrients(kcal: a.kcal + b.kcal, protein: a.protein + b.protein, fat: a.fat + b.fat, carbs: a.carbs + b.carbs,
                  fiber: a.fiber + b.fiber, sugars: a.sugars + b.sugars, satFat: a.satFat + b.satFat, salt: a.salt + b.salt)
    }
    public static func * (a: Nutrients, k: Double) -> Nutrients {
        Nutrients(kcal: a.kcal * k, protein: a.protein * k, fat: a.fat * k, carbs: a.carbs * k,
                  fiber: a.fiber * k, sugars: a.sugars * k, satFat: a.satFat * k, salt: a.salt * k)
    }

    /// Share of energy from protein, fat and carbs (0…1 each), for the macro ring.
    public var energySplit: (protein: Double, fat: Double, carbs: Double) {
        let p = protein * 4, f = fat * 9, c = carbs * 4, t = p + f + c
        return t > 0 ? (p / t, f / t, c / t) : (0, 0, 0)
    }

    public var json: [String: Any] {
        // Decimal, so JSONSerialization prints 1.9 and not 1.8999999999999999
        func r(_ x: Double, _ digits: Int = 1) -> Decimal { Decimal(string: String(format: "%.\(digits)f", x)) ?? 0 }
        return ["kcal": r(kcal, 0), "protein_g": r(protein), "fat_g": r(fat), "carbs_g": r(carbs), "fiber_g": r(fiber),
                "sugars_g": r(sugars), "saturated_fat_g": r(satFat), "salt_g": r(salt, 2)]
    }
}

/// How an ingredient got its nutrients.
public enum MatchStatus: String, Codable, Sendable, CaseIterable {
    case pending     // not analysed yet
    case matched     // a food from USDA or Open Food Facts
    case estimated   // the model's estimate (no good match in the databases)
    case manual      // fixed by hand; analysis never overwrites it
    case skipped     // no nutrition worth counting (water, salt "to taste", decoration)
    case failed      // analysis ran but found nothing

    public var label: String {
        switch self {
        case .pending: "Neanalyzované"
        case .matched: "Z databázy"
        case .estimated: "Odhad"
        case .manual: "Upravené ručne"
        case .skipped: "Nepočíta sa"
        case .failed: "Nenájdené"
        }
    }
}

public struct Ingredient: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64 = 0
    public var pos = 0
    /// The line as written in the recipe ("2 lyžice olivového oleja").
    public var line = ""
    /// Group heading the line belongs to ("Cesto", "Plnka"); empty for none.
    public var section = ""
    public var name = ""
    public var qty: Double?
    public var unit = ""
    /// Weight of the ingredient for the recipe's servings; nil when unknown.
    public var grams: Double?
    /// "usda:171077", "off:8588000282210", "ai" (estimate) or "custom".
    public var foodRef: String?
    public var foodName: String?
    public var per100: Nutrients?
    public var status: MatchStatus = .pending
    public var note = ""

    public init(line: String = "", section: String = "") { self.line = line; self.section = section }

    public var nutrients: Nutrients? {
        guard status != .skipped, let g = grams, let p = per100 else { return nil }
        return p * (g / 100)
    }
    /// Counts toward the totals (or knowingly doesn't).
    public var isResolved: Bool { status == .skipped || nutrients != nil }
    public var displayName: String { name.isEmpty ? line : name }
}

/// A photo of the original recipe (a cookbook page, a handwritten card), kept with the recipe in the archive, with the text
/// read from it.
public struct SourcePhoto: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64 = 0
    /// In the archive (Store.photosDir); for a new photo (id 0) the file to copy there on save.
    public var path: String
    public var text = ""
    public var added = ""
    public init(path: String, text: String = "") { self.path = path; self.text = text }
}

public struct Recipe: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64 = 0
    public var title = ""
    public var servings = 4.0
    /// Weight of the finished dish (the whole pot), when weighed; makes "I ate 340 g" exact.
    public var yieldGrams: Double?
    public var prepMin: Int?
    public var cookMin: Int?
    public var sourceURL = ""
    public var imagePath = ""
    public var tags: [String] = []
    public var notes = ""
    /// Who the recipe is from ("babka Mária", "teta Eva", a cookbook).
    public var author = ""
    public var steps: [String] = []
    /// Photos of the original, oldest first.
    public var photos: [SourcePhoto] = []
    public var favorite = false
    public var created = ""
    public var updated = ""
    public var cookedCount = 0
    public var lastCooked: String?
    public var ingredients: [Ingredient] = []

    public init(title: String = "") { self.title = title }

    public var total: Nutrients { ingredients.compactMap(\.nutrients).reduce(.zero, +) }
    public var perServing: Nutrients { total * (1 / max(servings, 0.01)) }
    /// Raw weight of everything that went in (what a dish weighs when it isn't weighed after cooking).
    public var rawGrams: Double { ingredients.filter { $0.status != .skipped }.compactMap(\.grams).reduce(0, +) }
    /// Weight of the finished dish: the weighed one, otherwise the raw weight.
    public var dishGrams: Double { yieldGrams ?? rawGrams }
    public var per100: Nutrients { dishGrams > 0 ? total * (100 / dishGrams) : .zero }
    public var gramsPerServing: Double { dishGrams / max(servings, 0.01) }
    public var unresolved: [Ingredient] { ingredients.filter { !$0.isResolved } }
    public var needsAnalysis: Bool { ingredients.contains { $0.status == .pending } }
    public var hasEstimates: Bool { ingredients.contains { $0.status == .estimated } }
    /// What a tile shows: the dish photo, else the first photo of the original.
    public var coverPath: String { imagePath.isEmpty ? (photos.first?.path ?? "") : imagePath }
    public var totalMin: Int? { prepMin == nil && cookMin == nil ? nil : (prepMin ?? 0) + (cookMin ?? 0) }
    /// Section names in order of first appearance.
    public var sections: [String] {
        var seen: [String] = []
        for i in ingredients where !seen.contains(i.section) { seen.append(i.section) }
        return seen
    }
}

public enum MealSlot: String, Codable, CaseIterable, Sendable {
    case breakfast, lunch, dinner, snack
    public var label: String {
        switch self { case .breakfast: "Raňajky"; case .lunch: "Obed"; case .dinner: "Večera"; case .snack: "Desiata" }
    }
    public var symbol: String {
        switch self { case .breakfast: "sunrise"; case .lunch: "sun.max"; case .dinner: "moon.stars"; case .snack: "carrot" }
    }
    public static func parse(_ s: String?) -> MealSlot? {
        guard let s else { return nil }
        let k = fold(s)
        if let m = MealSlot(rawValue: k) { return m }
        if k.hasPrefix("ran") { return .breakfast }
        if k.hasPrefix("ob") { return .lunch }
        if k.hasPrefix("vec") { return .dinner }
        if k.hasPrefix("des") || k.hasPrefix("olo") || k.hasPrefix("snack") || k.hasPrefix("mej") { return .snack }
        return nil
    }
}

/// Something eaten: a portion of a recipe (by grams or servings) or a free entry.
public struct Meal: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64 = 0
    public var date = ""
    public var slot: MealSlot = .lunch
    public var recipeId: Int64?
    public var title = ""
    public var grams: Double?
    public var servings: Double?
    public var nutrients = Nutrients.zero
    public var created = ""
    public init() {}
}

/// A recipe planned for a day.
public struct PlanItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64 = 0
    public var date = ""
    public var slot: MealSlot = .lunch
    public var recipeId: Int64 = 0
    public var servings = 2.0
    public var title = ""
    public var note = ""
    public init() {}
}

/// Case and diacritics insensitive key ("Olivový olej" → "olivovy olej").
public func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum Day {
    static let f: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    public static var today: String { f.string(from: Date()) }
    public static func string(_ d: Date) -> String { f.string(from: d) }
    public static func date(_ s: String) -> Date? { f.date(from: String(s.prefix(10))) }
    public static func adding(_ days: Int, to s: String) -> String {
        guard let d = date(s), let n = Calendar.current.date(byAdding: .day, value: days, to: d) else { return s }
        return string(n)
    }
    /// Monday of the week the day is in.
    public static func weekStart(_ s: String) -> String {
        guard let d = date(s) else { return s }
        var c = Calendar(identifier: .iso8601); c.timeZone = .current
        return string(c.dateInterval(of: .weekOfYear, for: d)?.start ?? d)
    }
    public static var now: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
    }
}
