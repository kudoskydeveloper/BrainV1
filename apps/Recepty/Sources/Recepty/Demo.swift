import Foundation
import ReceptyCore

/// `Recepty --demo <dir>`: a separate database in <dir> with a few analysed recipes, a plan and a meal log, for trying the
/// app and for snapshots without touching real data and without the model.
enum Demo {
    static func applyArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count else { return }
        try? FileManager.default.createDirectory(atPath: args[i + 1], withIntermediateDirectories: true)
        setenv("RECEPTY_DB", (args[i + 1] as NSString).appendingPathComponent("recepty.sqlite"), 1)
        if let s = try? Store(), s.recipes().isEmpty { fill(s) }
    }

    /// (line, section, name, qty, unit, grams, USDA query)
    typealias Line = (String, String, String, Double?, String, Double, String)

    static func fill(_ s: Store) {
        let recipes: [(String, Double, Int, Int, [String], [Line], [String])] = [
            ("Bryndzové halušky so slaninou", 4, 20, 25, ["slovenské", "hlavné jedlo"], [
                ("1 kg zemiakov", "Halušky", "zemiaky", 1, "kg", 1000, "potatoes raw flesh skin"),
                ("400 g hladkej múky", "Halušky", "hladká múka", 400, "g", 400, "wheat flour white all-purpose"),
                ("1 vajce", "Halušky", "vajce", 1, "ks", 55, "egg whole raw fresh"),
                ("1 ČL soli", "Halušky", "soľ", 1, "ČL", 6, "salt table"),
                ("300 g bryndze", "Navrch", "bryndza", 300, "g", 300, "cheese feta"),
                ("150 g údenej slaniny", "Navrch", "slanina", 150, "g", 150, "pork bacon raw"),
                ("100 ml kyslej smotany", "Navrch", "kyslá smotana", 100, "ml", 100, "cream sour cultured"),
            ], ["Zemiaky ošúpeme a najemno nastrúhame. Pridáme múku, vajce a soľ a vypracujeme husté cesto.",
                "Cesto pretláčame cez haluškovač do vriacej osolenej vody. Varíme 3 minúty, kým halušky nevyplávajú.",
                "Slaninu nakrájame na kocky a opražíme dochrumkava, asi 8 minút.",
                "Scedené halušky zmiešame s bryndzou a smotanou, posypeme slaninou a podávame hneď."]),
            ("Kuracie prsia s ryžou a brokolicou", 2, 10, 25, ["fit", "rýchle"], [
                ("300 g kuracích pŕs", "", "kuracie prsia", 300, "g", 300, "chicken breast meat only raw"),
                ("150 g ryže", "", "ryža", 150, "g", 150, "rice white long-grain raw"),
                ("300 g brokolice", "", "brokolica", 300, "g", 300, "broccoli raw"),
                ("1 PL olivového oleja", "", "olivový olej", 1, "PL", 14, "oil olive"),
                ("1 strúčik cesnaku", "", "cesnak", 1, "strúčik", 5, "garlic raw"),
            ], ["Ryžu prepláchneme a varíme 15 minút.", "Kuracie prsia osolíme a opečieme na oleji z každej strany 6 minút.",
                "Brokolicu varíme na pare 5 minút, s cesnakom ju podusíme na panvici.", "Podávame spolu."]),
            ("Tvarohové palacinky", 4, 15, 20, ["dezert", "vegetariánske"], [
                ("250 ml polotučného mlieka", "Cesto", "polotučné mlieko", 250, "ml", 258, "milk reduced fat 2%"),
                ("120 g hladkej múky", "Cesto", "hladká múka", 120, "g", 120, "wheat flour white all-purpose"),
                ("2 vajcia", "Cesto", "vajce", 2, "ks", 110, "egg whole raw fresh"),
                ("250 g mäkkého tvarohu", "Plnka", "tvaroh", 250, "g", 250, "cheese cottage lowfat 2%"),
                ("2 PL cukru", "Plnka", "cukor", 2, "PL", 25, "sugars granulated"),
                ("1 ČL oleja na panvicu", "", "olej", 1, "ČL", 5, "oil sunflower"),
            ], ["Mlieko, múku a vajcia vyšľaháme na hladké cesto a necháme 10 minút odpočívať.",
                "Na rozpálenej panvici s kvapkou oleja pečieme tenké palacinky, z každej strany asi 1 minútu.",
                "Tvaroh vymiešame s cukrom, natrieme na palacinky a zrolujeme."]),
        ]
        var ids: [Int64] = []
        for (title, servings, prep, cook, tags, lines, steps) in recipes {
            var r = Recipe(title: title)
            r.servings = servings; r.prepMin = prep; r.cookMin = cook; r.tags = tags; r.steps = steps
            r.ingredients = lines.map { l in
                var i = Ingredient(line: l.0, section: l.1)
                i.name = l.2; i.qty = l.3; i.unit = l.4; i.grams = l.5
                if l.2 == "soľ" { i.status = .skipped; i.grams = nil; return i }
                if let f = FoodDB.shared?.search(l.6, limit: 1).first {
                    i.foodRef = f.id; i.foodName = f.displayName; i.per100 = f.per100; i.status = .matched
                } else { i.status = .failed }
                return i
            }
            if title.hasPrefix("Bryndz") { r.favorite = true; r.yieldGrams = 1900 }
            if let saved = try? s.save(r) { ids.append(saved.id) }
        }
        let week = Day.weekStart(Day.today)
        for (n, id) in ids.enumerated() {
            var p = PlanItem(); p.recipeId = id; p.date = Day.adding(n * 2, to: week); p.slot = n == 2 ? .dinner : .lunch; p.servings = 2
            _ = try? s.save(p)
            if let r = s.recipe(id) {
                for d in 0..<5 where (d + n) % 2 == 0 {
                    _ = try? s.logMeal(recipe: r, grams: n == 0 ? 420 : nil, servings: n == 0 ? nil : 1, date: Day.adding(-d, to: Day.today), slot: n == 2 ? .dinner : .lunch)
                }
            }
        }
    }
}
