import ReceptyCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            NavigationStack(path: $model.path) {
                page
                    .navigationDestination(for: Int64.self) { id in
                        if let r = model.recipe(id) { RecipePage(model: model, recipe: r) }
                        else { ContentUnavailableView("Recept neexistuje", systemImage: "fork.knife") }
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { model.sheet = .importer } label: { Label("Z odkazu alebo textu…", systemImage: "link") }
                    Button { model.sheet = .edit(Recipe()) } label: { Label("Prázdny recept…", systemImage: "square.and.pencil") }
                } label: { Label("Nový recept", systemImage: "plus") } primaryAction: { model.sheet = .importer }
                .help("Pridať recept z odkazu alebo textu (⌘N)")
            }
        }
        .sheet(item: $model.sheet) { s in SheetView(sheet: s, model: model) }
        .alert("Nepodarilo sa", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .frame(minWidth: 960, minHeight: 620)
        .onAppear {
            model.openMain = { [openWindow] in openWindow(id: "main") }
            model.openCook = { [openWindow] id in openWindow(id: "cook", value: id) }
        }
    }

    @ViewBuilder var page: some View {
        switch model.page ?? .all {
        case .plan: PlanPage(model: model)
        case .log: LogPage(model: model)
        case .shopping: ShoppingPage(model: model)
        default: LibraryPage(model: model)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.page }, set: { model.page = $0; model.path = [] })) {
            Section("Recepty") {
                row("Všetky", "book.closed.fill", .orange, .all, badge: model.recipes.count)
                row("Obľúbené", "heart.fill", .pink, .favorites, badge: model.recipes.filter(\.favorite).count)
                row("Naposledy jedené", "clock.fill", .teal, .recent)
            }
            Section("Plán") {
                row("Jedálniček", "calendar", .purple, .plan)
                row("Denník", "chart.bar.doc.horizontal.fill", .green, .log)
                row("Nákup", "cart.fill", .blue, .shopping)
            }
            if !model.authors.isEmpty {
                Section("Od koho") {
                    ForEach(model.authors, id: \.self) { a in
                        Label(a, systemImage: "person.crop.circle").badge(model.recipes.filter { $0.author == a }.count).tag(Page.author(a))
                    }
                }
            }
            if !model.tags.isEmpty {
                Section("Štítky") {
                    ForEach(model.tags, id: \.self) { t in
                        Label(t, systemImage: "tag").tag(Page.tag(t))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    func row(_ title: String, _ symbol: String, _ color: Color, _ page: Page, badge: Int = 0) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .badge(badge)
            .tag(page)
    }
}

// MARK: Library

struct LibraryPage: View {
    @ObservedObject var model: AppModel
    @Environment(\.snapshot) private var snapshot

    var title: String {
        switch model.page ?? .all {
        case .favorites: "Obľúbené"
        case .recent: "Naposledy jedené"
        case .tag(let t): t.prefix(1).uppercased() + t.dropFirst()
        case .author(let a): "Od: \(a)"
        default: "Recepty"
        }
    }

    var body: some View {
        let list = model.visible
        Group {
            if model.recipes.isEmpty {
                ContentUnavailableView {
                    Label("Zatiaľ žiadne recepty", systemImage: "fork.knife")
                } description: {
                    Text("Vlož odkaz na recept z webu alebo text receptu. Recepty spočítajú kalórie a makrá z databázy potravín USDA a Open Food Facts.")
                } actions: {
                    Button("Pridať recept…") { model.sheet = .importer }.buttonStyle(.borderedProminent)
                }
            } else if list.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                LibraryContent(model: model, title: title, list: list)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(list.isEmpty ? "" : "\(list.count) \(list.count == 1 ? "recept" : list.count < 5 ? "recepty" : "receptov")")
        .searchable(text: $model.search, placement: .toolbar, prompt: "Hľadať recept alebo surovinu")
    }
}

struct ImportBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").foregroundStyle(.orange)
            Text("Pridávam recept · \(text)").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .cardBackground()
    }
}

/// The library itself: a large title, what's planned for the next days, and the recipes as covers (like Apple Books).
struct LibraryContent: View {
    @ObservedObject var model: AppModel
    let title: String
    let list: [Recipe]

    var body: some View {
        let _ = model.version
        let upcoming = (model.page ?? .all) == .all && model.search.isEmpty
            ? model.store.plan(from: Day.today, to: Day.adding(2, to: Day.today)) : []
        ScrollPage(maxWidth: 1400) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            if let b = model.busy[0] { ImportBanner(text: b) }
            if !upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Na programe").font(.title3.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(upcoming) { p in
                                if let r = model.recipe(p.recipeId) {
                                    Button { model.open(r.id) } label: { UpcomingCard(item: p, recipe: r) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
                if !list.isEmpty { Text("Všetky recepty").font(.title3.weight(.semibold)) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 22, alignment: .top)], spacing: 26) {
                ForEach(list) { r in
                    Button { model.open(r.id) } label: { RecipeTile(recipe: r, busy: model.busy[r.id]) }
                        .buttonStyle(.plain)
                        .contextMenu { RecipeMenu(model: model, recipe: r) }
                }
            }
        }
    }

    var subtitle: String {
        let n = list.count
        var s = "\(n) \(n == 1 ? "recept" : n > 1 && n < 5 ? "recepty" : "receptov")"
        let fav = list.filter(\.favorite).count
        if fav > 0, (model.page ?? .all) != .favorites { s += " · \(fav) obľúbené" }
        return s
    }
}

/// A planned meal in the "Na programe" strip.
struct UpcomingCard: View {
    let item: PlanItem
    let recipe: Recipe
    var body: some View {
        HStack(spacing: 12) {
            RecipeImage(path: recipe.coverPath, corner: 10).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Day.friendly(item.date)) · \(item.slot.label)".uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                Text(recipe.title).font(.headline).lineLimit(2)
                Text("\(Fmt.number(item.servings)) porc." + (recipe.totalMin.map { " · \(Fmt.minutes($0))" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 300)
        .cardBackground()
    }
}

/// A recipe as a cover: the photo without a frame, the title and its numbers under it; lifts a little under the pointer.
struct RecipeTile: View {
    let recipe: Recipe
    var busy: String?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { RecipeImage(path: recipe.coverPath, corner: 0).scaleEffect(hover ? 1.04 : 1) }
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .overlay(alignment: .topLeading) {
                    if let t = recipe.totalMin {
                        Label(Fmt.minutes(t), systemImage: "timer")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if recipe.favorite {
                        Image(systemName: "heart.fill").font(.caption).foregroundStyle(.white)
                            .padding(7).background(.pink.gradient, in: Circle()).padding(10)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !recipe.photos.isEmpty && recipe.imagePath.isEmpty {
                        Label("Originál", systemImage: "doc.text.image")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: Capsule()).padding(10)
                    }
                }
                .shadow(color: .black.opacity(hover ? 0.22 : 0.10), radius: hover ? 14 : 6, y: hover ? 8 : 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.title).font(.headline).lineLimit(2)
                Text(byline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    if let busy {
                        Label(busy, systemImage: "wand.and.stars").foregroundStyle(.orange)
                    } else if recipe.needsAnalysis || recipe.ingredients.isEmpty {
                        Text("Bez výživových hodnôt").foregroundStyle(.tertiary)
                    } else {
                        Text(Fmt.kcal(recipe.perServing.kcal)).foregroundStyle(Color.energy).fontWeight(.semibold)
                        ForEach(Macro.allCases, id: \.self) { m in
                            HStack(spacing: 3) {
                                Circle().fill(m.color).frame(width: 6, height: 6)
                                Text(Fmt.macro(m.grams(recipe.perServing))).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .padding(.top, 1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(.rect)
        .onHover { h in withAnimation(.snappy(duration: 0.25)) { hover = h } }
        .accessibilityElement(children: .combine)
    }

    var byline: String {
        if !recipe.author.isEmpty { return "Od: \(recipe.author)" }
        if !recipe.tags.isEmpty { return recipe.tags.prefix(2).joined(separator: " · ") }
        return recipe.sourceURL.isEmpty ? "Vlastný recept" : (URL(string: recipe.sourceURL)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "")
    }
}

struct RecipeMenu: View {
    @ObservedObject var model: AppModel
    let recipe: Recipe
    var body: some View {
        Button("Variť") { model.cook(recipe) }
        Button("Zjedol som…") { model.sheet = .logMeal(recipe, 1) }
        Button("Naplánovať…") { model.sheet = .planRecipe(recipe, Day.today) }
        Divider()
        Button(recipe.favorite ? "Odobrať z obľúbených" : "Pridať k obľúbeným") { model.toggleFavorite(recipe) }
        Button("Upraviť…") { model.sheet = .edit(recipe) }
        Button("Pridať fotku originálu…") { model.pickPhotos(for: recipe) }
        Button("Analyzovať znova") { model.analyze(recipe, all: true) }
        if !recipe.sourceURL.isEmpty, let u = URL(string: recipe.sourceURL) { Button("Otvoriť pôvodný recept") { NSWorkspace.shared.open(u) } }
        Divider()
        Button("Zmazať…", role: .destructive) { model.delete(recipe) }
    }
}
