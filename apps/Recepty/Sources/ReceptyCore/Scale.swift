import Foundation

/// Numbers the way a cook reads them: "½", "1¼", "250", "1,5".
public enum Fmt {
    static let fractions: [(Double, String)] = [(0.125, "⅛"), (0.25, "¼"), (1.0 / 3, "⅓"), (0.5, "½"), (2.0 / 3, "⅔"), (0.75, "¾")]

    public static func qty(_ v: Double) -> String {
        if v >= 10 { return number(v.rounded()) }
        let whole = v.rounded(.down), frac = v - whole
        if frac < 0.06 { return number(whole) }
        if frac > 0.94 { return number(whole + 1) }
        if let f = fractions.first(where: { abs($0.0 - frac) < 0.04 }) { return (whole > 0 ? number(whole) : "") + f.1 }
        return number((v * 10).rounded() / 10)
    }

    public static func number(_ v: Double, digits: Int = 1) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "sk_SK")
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Grams rounded so they look weighed: 3 g, 45 g, 120 g, 1,2 kg.
    public static func grams(_ g: Double) -> String {
        if g >= 1000 { return "\(number(g / 1000, digits: 2)) kg" }
        if g >= 100 { return "\(number((g / 5).rounded() * 5, digits: 0)) g" }
        if g >= 10 { return "\(number(g.rounded(), digits: 0)) g" }
        return "\(number(g, digits: 1)) g"
    }

    public static func kcal(_ v: Double) -> String { "\(number(v.rounded(), digits: 0)) kcal" }
    public static func macro(_ v: Double) -> String { "\(number(v, digits: v < 10 ? 1 : 0)) g" }

    public static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

public extension Ingredient {
    /// The line for `factor` times the recipe: the amount scaled when it's known, otherwise the line as written.
    func scaledLine(_ factor: Double) -> String {
        guard abs(factor - 1) > 0.001, let q = qty, q > 0 else { return line }
        let unitPart = unit.isEmpty ? "" : " \(unit)"
        return "\(Fmt.qty(q * factor))\(unitPart) \(name)"
    }
    func scaledGrams(_ factor: Double) -> Double? { grams.map { $0 * factor } }
}

/// A timer mentioned in a step ("varíme 20 minút", "pečieme 1 hodinu", "10–15 min").
public struct StepTimer: Equatable, Sendable {
    public var label: String
    public var seconds: Int
}

public extension String {
    var timers: [StepTimer] {
        let re = try! NSRegularExpression(pattern: #"(\d+)(?:\s*[-–]\s*(\d+))?\s*(sekúnd|sek|s\b|minút|minúty|minútu|min|hodín|hodiny|hodinu|hod|h\b|minutes?|mins?|hours?)"#,
                                          options: .caseInsensitive)
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let a = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let b = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? a : a
            let u = ns.substring(with: m.range(at: 3)).lowercased()
            let mult = u.hasPrefix("h") ? 3600 : u.hasPrefix("s") ? 1 : 60
            let n = max(a, b) * mult
            guard n > 0, n <= 24 * 3600 else { return nil }
            return StepTimer(label: ns.substring(with: m.range), seconds: n)
        }
    }
}

/// What to buy for planned recipes: the same food from several recipes is added up (grams when known).
public struct ShoppingItem: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var grams: Double?
    /// Lines that couldn't be added up (no weight).
    public var other: [String]
    public var recipes: [String]

    public var label: String {
        var parts: [String] = []
        if let g = grams, g > 0 { parts.append(Fmt.grams(g)) }
        parts += other
        return parts.isEmpty ? name : "\(name) – \(parts.joined(separator: " + "))"
    }
}

public enum Shopping {
    /// Items for (recipe, servings) pairs, skipping water and seasoning without amount.
    public static func list(_ items: [(Recipe, Double)]) -> [ShoppingItem] {
        var by: [String: ShoppingItem] = [:], order: [String] = []
        for (r, servings) in items {
            let k = servings / max(r.servings, 0.01)
            for i in r.ingredients where i.status != .skipped {
                let name = i.name.isEmpty ? i.line : i.name
                let key = Store.aliasKey(name)
                if by[key] == nil { by[key] = ShoppingItem(name: name, grams: nil, other: [], recipes: []); order.append(key) }
                if let g = i.grams { by[key]!.grams = (by[key]!.grams ?? 0) + g * k }
                else { by[key]!.other.append(i.scaledLine(k)) }
                if !by[key]!.recipes.contains(r.title) { by[key]!.recipes.append(r.title) }
            }
        }
        return order.compactMap { by[$0] }
    }
}
