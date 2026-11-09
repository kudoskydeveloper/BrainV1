import AppKit
import ReceptyCore
import SwiftUI

struct RecipePage: View {
    @ObservedObject var model: AppModel
    let recipe: Recipe
    /// Portion calculator: servings to cook (nil = as in the recipe).
    @State private var servings: Double?
    /// Page width: ingredients beside the steps when there is room.
    @State private var width: CGFloat = 1000
    @Environment(\.snapshot) private var snapshot

    var r: Recipe { recipe }
    var cookServings: Double { servings ?? r.servings }
    var factor: Double { cookServings / max(r.servings, 0.01) }

    var body: some View {
        ScrollPage {
            Hero(model: model, recipe: r)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            if let b = model.busy[r.id] { banner(b, symbol: "wand.and.stars", tint: .orange) }
            else if r.ingredients.isEmpty { banner("Recept nemá suroviny. Doplň ich v úprave.", symbol: "list.bullet", tint: .secondary) }
            else if r.needsAnalysis { banner("Suroviny ešte nie sú zanalyzované.", symbol: "circle.dotted", tint: .secondary, action: ("Analyzovať", { model.analyze(r) })) }
            else if !r.unresolved.isEmpty { banner("\(r.unresolved.count) \(r.unresolved.count == 1 ? "surovina sa nepočíta" : "suroviny sa nepočítajú") – klikni na ňu a vyber potravinu.", symbol: "exclamationmark.triangle.fill", tint: .red) }
            if !r.ingredients.isEmpty, !r.needsAnalysis { NutritionCard(recipe: r, factor: factor) }
            if width >= 860 {
                HStack(alignment: .top, spacing: 16) {
                    ingredientsCard.frame(width: min(460, width * 0.44))
                    stepsCard
                }
            } else {
                VStack(spacing: 16) { ingredientsCard; stepsCard }
            }
            if !r.photos.isEmpty { originals }
            if !r.notes.isEmpty {
                Card("Poznámky") { Text(r.notes).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(r.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.toggleFavorite(r) } label: { Label("Obľúbené", systemImage: r.favorite ? "heart.fill" : "heart") }
                    .help(r.favorite ? "Odobrať z obľúbených" : "Pridať k obľúbeným")
                Button { model.sheet = .edit(r) } label: { Label("Upraviť", systemImage: "pencil") }.help("Upraviť recept")
                Menu {
                    RecipeMenu(model: model, recipe: r)
                } label: { Label("Viac", systemImage: "ellipsis.circle") }
            }
        }
        .onChange(of: r.id) { _, _ in servings = nil }
    }

    func banner(_ text: String, symbol: String, tint: Color, action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
        .padding(12)
        .cardBackground()
    }

    // MARK: Ingredients

    var ingredientsCard: some View {
        Card("Suroviny", subtitle: factor == 1 ? "na \(Fmt.number(r.servings)) porc." : "prepočítané z \(Fmt.number(r.servings)) porc.") {
            PortionStepper(value: Binding(get: { cookServings }, set: { servings = abs($0 - r.servings) < 0.001 ? nil : $0 }), original: r.servings)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(r.sections, id: \.self) { sec in
                    if !sec.isEmpty {
                        Text(sec.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.orange).tracking(0.5)
                            .padding(.top, 12).padding(.bottom, 2)
                    }
                    let rows = Array(r.ingredients.enumerated()).filter { $0.element.section == sec }
                    ForEach(rows, id: \.element.id) { idx, ing in
                        IngredientRow(ing: ing, factor: factor) { model.sheet = .fix(r, idx) }
                        if idx != rows.last?.offset { Divider().padding(.leading, 96) }
                    }
                }
            }
        }
    }

    var stepsCard: some View {
        Card("Postup", subtitle: r.steps.isEmpty ? nil : "\(r.steps.count) \(r.steps.count < 5 ? "kroky" : "krokov")\(r.totalMin.map { " · \(Fmt.minutes($0))" } ?? "")") {
            if !r.steps.isEmpty {
                Button { model.cook(r) } label: { Label("Variť", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
            }
        } content: {
            if r.steps.isEmpty { Text("Bez postupu.").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(r.steps.enumerated()), id: \.offset) { n, s in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(n + 1)")
                            .font(.system(.callout, design: .rounded).weight(.bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(Color.orange.gradient, in: Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            let t = s.timers
                            if !t.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(Array(t.enumerated()), id: \.offset) { _, x in
                                        Label(CookTimers.format(x.seconds), systemImage: "timer").font(.caption.weight(.medium)).foregroundStyle(.orange)
                                            .padding(.horizontal, 7).padding(.vertical, 2).background(.orange.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The archived photos of the original (a cookbook page, grandma's handwriting).
    var originals: some View {
        Card("Originál", subtitle: "\(r.photos.count) \(r.photos.count == 1 ? "fotka" : r.photos.count < 5 ? "fotky" : "fotiek") · klikni pre zväčšenie") {
            Button { model.pickPhotos(for: r) } label: { Label("Pridať fotku", systemImage: "plus") }.buttonStyle(.borderless)
        } content: {
            let row = HStack(spacing: 14) {
                ForEach(Array(r.photos.enumerated()), id: \.element.id) { n, p in
                    Button { model.sheet = .photos(r.id, n) } label: {
                        RecipeImage(path: p.path, corner: 8).frame(width: 150, height: 200)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.15), radius: 5, y: 3)
                            .rotationEffect(.degrees(n % 2 == 0 ? -1.2 : 1.0))
                    }
                    .buttonStyle(.plain)
                    .help("Zobraziť originál")
                }
            }
            .padding(8)
            if snapshot { row } else { ScrollView(.horizontal, showsIndicators: false) { row } }
        }
    }
}

// MARK: Hero

/// The top of a recipe like an album in Music: the photo large with its own colours blurred behind, the title, who it's
/// from, the facts in capsules and the actions.
struct Hero: View {
    @ObservedObject var model: AppModel
    let recipe: Recipe
    var r: Recipe { recipe }

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            RecipeImage(path: r.coverPath, corner: 16)
                .frame(width: 230, height: 230)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                .onTapGesture { if r.imagePath.isEmpty, !r.photos.isEmpty { model.sheet = .photos(r.id, 0) } }
            VStack(alignment: .leading, spacing: 12) {
                if !r.author.isEmpty {
                    Button { model.page = .author(r.author); model.path = [] } label: {
                        Label(r.author, systemImage: "person.crop.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain).help("Všetky recepty od: \(r.author)")
                }
                Text(r.title).font(.system(size: 34, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                FlowRow(spacing: 8) {
                    if let p = r.prepMin { Pill(symbol: "knife", text: "Príprava \(Fmt.minutes(p))") }
                    if let c = r.cookMin { Pill(symbol: "flame", text: "Varenie \(Fmt.minutes(c))") }
                    Pill(symbol: "person.2", text: "\(Fmt.number(r.servings)) porc.")
                    if r.cookedCount > 0 { Pill(symbol: "fork.knife", text: "Jedené \(r.cookedCount)×") }
                    ForEach(r.tags, id: \.self) { Pill(symbol: "tag", text: $0, tint: .orange) }
                }
                if !r.sourceURL.isEmpty, let u = URL(string: r.sourceURL) {
                    Link(destination: u) { Label(u.host()?.replacingOccurrences(of: "www.", with: "") ?? "Zdroj", systemImage: "arrow.up.right.square") }
                        .font(.callout)
                }
                HStack(spacing: 10) {
                    Button { model.cook(r) } label: { Label("Variť", systemImage: "frying.pan.fill").padding(.horizontal, 6) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    Button { model.sheet = .logMeal(r, 1) } label: { Label("Zjedol som", systemImage: "checkmark.circle") }
                        .disabled(r.needsAnalysis || r.ingredients.isEmpty)
                    Button { model.sheet = .planRecipe(r, Day.today) } label: { Label("Naplánovať", systemImage: "calendar.badge.plus") }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RecipeImage(path: r.coverPath, corner: 0).scaleEffect(1.6).blur(radius: 60).opacity(0.65)
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            }
            .clipped()
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Views laid out left to right, wrapping to the next line.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { y += lineH + spacing; x = 0; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += lineH + spacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

/// − 4 porcie +, with a reset to the recipe's servings.
struct PortionStepper: View {
    @Binding var value: Double
    let original: Double
    var body: some View {
        HStack(spacing: 2) {
            if abs(value - original) > 0.001 {
                Button { value = original } label: { Image(systemName: "arrow.uturn.backward").font(.caption) }
                    .buttonStyle(.borderless).help("Späť na \(Fmt.number(original)) porc.").padding(.trailing, 6)
            }
            Button { value = max(1, (value - 1).rounded()) } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                .disabled(value <= 1)
            Text("\(Fmt.number(value))").font(.body.weight(.semibold)).monospacedDigit().frame(minWidth: 26)
                .contentTransition(.numericText())
            Button { value = (value + 1).rounded(.down) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.primary.opacity(0.06), in: Capsule())
        .animation(.snappy, value: value)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Počet porcií")
    }
}

/// One ingredient: the amount in its own column, the food, its weight and calories; status only when something needs a look.
struct IngredientRow: View {
    let ing: Ingredient
    let factor: Double
    let fix: () -> Void
    @State private var hover = false

    var amount: String {
        guard let q = ing.qty, q > 0 else { return "" }
        return ing.unit.isEmpty ? Fmt.qty(q * factor) : "\(Fmt.qty(q * factor)) \(ing.unit)"
    }
    var title: String { amount.isEmpty || ing.name.isEmpty ? ing.scaledLine(factor) : ing.name }

    var body: some View {
        Button(action: fix) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(amount).font(.body.weight(.semibold)).monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 84, alignment: .trailing)
                    .layoutPriority(1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(ing.status == .skipped ? .secondary : .primary)
                    if let f = ing.foodName, ing.status != .skipped, hover || ing.status == .estimated {
                        Text(f).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if [.estimated, .failed, .pending].contains(ing.status) {
                    Image(systemName: ing.status.symbol).foregroundStyle(ing.status.color).font(.caption).help(ing.status.label)
                }
                if let g = ing.scaledGrams(factor), ing.status != .skipped, Analyzer.exactGrams(qty: ing.qty, unit: ing.unit) == nil {
                    Text(Fmt.grams(g)).font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if let n = ing.nutrients {
                    Text(Fmt.number((n.kcal * factor).rounded(), digits: 0)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(hover ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(ing.line + " · " + ing.status.label + (ing.foodName.map { ": \($0)" } ?? ""))
    }
}

/// Nutrition of one serving as Fitness's "Dnes": the ring and the macros, then the weights, and every value on request.
struct NutritionCard: View {
    let recipe: Recipe
    let factor: Double
    @State private var details = false
    @Environment(\.snapshot) private var snapshot

    var body: some View {
        let s = recipe.perServing
        Card("Výživa na porciu", subtitle: subtitle) {
            if recipe.hasEstimates { Label("Obsahuje odhady", systemImage: "wand.and.stars").font(.caption).foregroundStyle(.orange) }
        } content: {
            HStack(alignment: .center, spacing: 28) {
                NutritionSummary(n: s, ring: 116)
                Spacer(minLength: 12)
                Divider().frame(height: 90)
                VStack(alignment: .leading, spacing: 8) {
                    fact("scalemass", recipe.dishGrams > 0 ? "Porcia ≈ \(Fmt.grams(recipe.gramsPerServing))" : "Hmotnosť neznáma")
                    fact("100.square", "100 g · \(Fmt.kcal(recipe.per100.kcal))")
                    fact("frying.pan", "Celé jedlo · \(Fmt.kcal(recipe.total.kcal * factor))")
                }
                .font(.callout)
            }
            Button { withAnimation(.snappy) { details.toggle() } } label: {
                Label(details ? "Skryť podrobnosti" : "Všetky hodnoty", systemImage: details ? "chevron.up" : "chevron.down").font(.caption)
            }
            .buttonStyle(.borderless)
            if details || snapshot { table }
        }
    }

    func fact(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).monospacedDigit() } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
    }

    var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(["kcal", "Bielk.", "Sach.", "Tuky", "Vláknina", "Cukry", "Nasýt. tuky", "Soľ"], id: \.self) {
                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
            }
            row("Porcia", recipe.perServing)
            row("100 g", recipe.per100)
            row(factor == 1 ? "Celé jedlo" : "Celé jedlo (\(Fmt.number(recipe.servings * factor)) porc.)", recipe.total * factor)
        }
        .font(.callout.monospacedDigit())
        .padding(.top, 4)
    }

    var subtitle: String {
        var parts = ["z \(recipe.ingredients.count - recipe.unresolved.count) z \(recipe.ingredients.count) surovín"]
        if recipe.dishGrams > 0 { parts.append("jedlo \(Fmt.grams(recipe.dishGrams))\(recipe.yieldGrams == nil ? " surové" : " hotové")") }
        return parts.joined(separator: " · ")
    }

    func row(_ label: String, _ n: Nutrients) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(Fmt.number(n.kcal.rounded(), digits: 0))
            Text(Fmt.number(n.protein)); Text(Fmt.number(n.carbs)); Text(Fmt.number(n.fat))
            Text(Fmt.number(n.fiber)); Text(Fmt.number(n.sugars)); Text(Fmt.number(n.satFat)); Text(Fmt.number(n.salt, digits: 2))
        }
    }
}
