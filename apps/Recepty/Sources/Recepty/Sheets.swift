import AppKit
import PhotosUI
import ReceptyCore
import SwiftUI
import UniformTypeIdentifiers

struct SheetView: View {
    let sheet: Sheet
    @ObservedObject var model: AppModel
    var body: some View {
        switch sheet {
        case .importer: ImportSheet(model: model)
        case .edit(let r): EditSheet(model: model, recipe: r)
        case .fix(let r, let i): FixSheet(model: model, recipe: r, index: i)
        case .logMeal(let r, let s): LogMealSheet(model: model, recipe: r, servings: s)
        case .planRecipe(let r, let d): PlanSheet(model: model, recipe: r, date: d)
        case .photos(let id, let n): PhotoViewer(model: model, recipeId: id, index: n)
        }
    }
}

/// Bottom bar of every sheet: Cancel and the main action.
struct SheetButtons: View {
    let title: String
    var disabled = false
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack {
            Spacer()
            Button("Zrušiť") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(title, action: action).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(disabled)
        }
    }
}

// MARK: Import

struct ImportSheet: View {
    @ObservedObject var model: AppModel
    @State private var mode = 0
    @State private var url = ""
    @State private var text = ""
    /// Photos of the recipe, in page order (copied to a temporary folder).
    @State private var photos: [URL] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var dropping = false
    @State private var author = ""

    var busy: String? { model.busy[0] }

    var canAdd: Bool {
        switch mode {
        case 0: !url.trimmingCharacters(in: .whitespaces).isEmpty
        case 1: !text.trimmingCharacters(in: .whitespaces).isEmpty
        default: !photos.isEmpty && Importer.extractPath != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nový recept").font(.title2.weight(.semibold))
            Picker("", selection: $mode) {
                Text("Z odkazu").tag(0)
                Text("Z textu").tag(1)
                Text("Z fotky").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            switch mode {
            case 0:
                TextField("https://…", text: $url).textFieldStyle(.roundedBorder).font(.title3)
                Text("Funguje s väčšinou stránok s receptami (Varecha, Recepty.sk, BBC Good Food, …). Recept v inom jazyku sa preloží do slovenčiny.")
                    .font(.callout).foregroundStyle(.secondary)
            case 1:
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 220)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty { Text("Vlož recept: názov, suroviny, postup… v akejkoľvek podobe.").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                    }
                    .cardBackground()
            default:
                photoPicker
            }
            AuthorField(author: $author, known: model.authors, prompt: mode == 2 ? "napr. babka Mária (inak ho skúsi nájsť na fotke)" : "napr. babka Mária")
            if let busy {
                HStack(spacing: 8) { Image(systemName: "hourglass").symbolEffect(.pulse); Text(busy).foregroundStyle(.secondary) }
            } else if !AI.available, mode != 0 {
                Label("Na čítanie receptu treba claude CLI (prihlásenie ako v Brain).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if mode == 2, Importer.extractPath == nil {
                Label("Chýba OCR z Brainu (~/Developer/brain/tools/extract/brain-extract).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            SheetButtons(title: "Pridať", disabled: busy != nil || !canAdd) {
                switch mode {
                case 0: model.importRecipe(url: url, author: author)
                case 1: model.importRecipe(text: text, author: author)
                default: model.importRecipe(images: photos, author: author)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("http"), !s.contains(" ") { url = s }
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in mode = 2; load(providers) }
        .onChange(of: picked) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { add(data, ext: "jpg") }
                }
                picked = []
            }
        }
    }

    var photoPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(dropping ? Color.orange : Color.secondary.opacity(0.5))
                    .background(dropping ? Color.orange.opacity(0.08) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
                if photos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 34, weight: .light)).foregroundStyle(.orange)
                        Text("Odfoť recept (kniha, kartička, obrazovka) a pretiahni fotky sem").multilineTextAlignment(.center)
                        Text("alebo ich vlož (⌘V) či vyber nižšie. Viac strán jedného receptu v poradí.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(Array(photos.enumerated()), id: \.element) { n, u in
                                ZStack(alignment: .topTrailing) {
                                    RecipeImage(path: u.path, corner: 8).frame(width: 110, height: 140)
                                    Button { photos.remove(at: n) } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.5)) }
                                        .buttonStyle(.plain).padding(4)
                                }
                                .overlay(alignment: .bottomLeading) {
                                    Text("\(n + 1)").font(.caption.weight(.bold)).foregroundStyle(.white).padding(5).background(.black.opacity(0.45), in: Circle()).padding(4)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .frame(height: 170)
            .dropDestination(for: URL.self) { urls, _ in
                for u in urls { add(file: u) }
                return true
            } isTargeted: { dropping = $0 }
            HStack {
                PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) { Label("Z Fotiek…", systemImage: "photo.on.rectangle") }
                Button { pickFiles() } label: { Label("Zo súboru…", systemImage: "folder") }
                Spacer()
                Text("Fotky sa uložia k receptu ako originál.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static let tmp: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("recepty-import", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func add(_ data: Data, ext: String) {
        let f = Self.tmp.appendingPathComponent("\(UUID().uuidString).\(ext)")
        if (try? data.write(to: f)) != nil { photos.append(f) }
    }

    func add(file u: URL) {
        let ok = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp", "pdf"]
        guard ok.contains(u.pathExtension.lowercased()) else { return }
        let f = Self.tmp.appendingPathComponent("\(UUID().uuidString).\(u.pathExtension.lowercased())")
        if (try? FileManager.default.copyItem(at: u, to: f)) != nil { photos.append(f) }
    }

    func pickFiles() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .pdf]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls { add(file: u) } }
    }

    func load(_ providers: [NSItemProvider]) {
        for pr in providers {
            if pr.canLoadObject(ofClass: URL.self) {
                _ = pr.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { add(file: u) } } }
            } else if pr.canLoadObject(ofClass: NSImage.self) {
                _ = pr.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    DispatchQueue.main.async { add(png, ext: "png") }
                }
            }
        }
    }
}

/// "Od koho" with a menu of the names already used, so "babka Mária" is written the same way every time.
struct AuthorField: View {
    @Binding var author: String
    let known: [String]
    var prompt = ""
    var body: some View {
        HStack(spacing: 6) {
            TextField("Od koho", text: $author, prompt: Text(prompt))
            if !known.isEmpty {
                Menu {
                    ForEach(known, id: \.self) { a in Button(a) { author = a } }
                } label: { Image(systemName: "person.crop.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Vybrať z doterajších")
            }
        }
    }
}

// MARK: Edit

struct EditSheet: View {
    @ObservedObject var model: AppModel
    @State var recipe: Recipe
    @State private var ingredients = ""
    @State private var steps = ""
    @State private var tags = ""
    @State private var yield = ""

    init(model: AppModel, recipe: Recipe) {
        self.model = model
        _recipe = State(initialValue: recipe)
        _ingredients = State(initialValue: recipe.ingredientsText)
        _steps = State(initialValue: recipe.steps.joined(separator: "\n\n"))
        _tags = State(initialValue: recipe.tags.joined(separator: ", "))
        _yield = State(initialValue: recipe.yieldGrams.map { Fmt.number($0, digits: 0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(recipe.id == 0 ? "Nový recept" : "Upraviť recept").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Button { pickImage() } label: { RecipeImage(path: recipe.imagePath).frame(width: 180, height: 130) }
                        .buttonStyle(.plain).help("Vybrať fotku")
                        .dropDestination(for: URL.self) { urls, _ in if let u = urls.first { setImage(u) }; return true }
                    if !recipe.imagePath.isEmpty { Button("Odstrániť fotku") { recipe.imagePath = "" }.buttonStyle(.link).font(.caption) }
                }
                Form {
                    TextField("Názov", text: $recipe.title)
                    HStack {
                        TextField("Porcie", value: $recipe.servings, format: .number).frame(width: 140)
                        TextField("Hotové jedlo (g)", text: $yield, prompt: Text("odvážené"))
                            .help("Hmotnosť celého hotového jedla. S ňou je porcia v gramoch presná (varením sa mení hmotnosť).")
                    }
                    HStack {
                        TextField("Príprava (min)", value: $recipe.prepMin, format: .number)
                        TextField("Varenie (min)", value: $recipe.cookMin, format: .number)
                    }
                    TextField("Štítky", text: $tags, prompt: Text("polievka, rýchle"))
                    AuthorField(author: $recipe.author, known: model.authors, prompt: "babka Mária, kuchárka…")
                    TextField("Zdroj", text: $recipe.sourceURL, prompt: Text("https://…"))
                }
                .formStyle(.columns)
            }
            HStack(alignment: .top, spacing: 16) {
                editor("Suroviny", "Jedna na riadok. Skupina: riadok „# Cesto“.", $ingredients)
                editor("Postup", "Kroky oddelené prázdnym riadkom.", $steps)
            }
            editor("Poznámky", nil, $recipe.notes, height: 60)
            SheetButtons(title: "Uložiť", disabled: recipe.title.trimmingCharacters(in: .whitespaces).isEmpty) { save() }
        }
        .padding(20)
        .frame(width: 820)
    }

    func editor(_ title: String, _ hint: String?, _ text: Binding<String>, height: CGFloat = 260) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.headline); if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) } }
            TextEditor(text: text).font(.body).frame(height: height).padding(4).cardBackground()
        }
    }

    func save() {
        var r = recipe
        r.title = r.title.trimmingCharacters(in: .whitespaces)
        r.servings = max(r.servings, 0.5)
        r.yieldGrams = Double(yield.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")).flatMap { $0 > 0 ? $0 : nil }
        r.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        r.ingredients = Recipe.ingredients(fromText: ingredients, keeping: recipe.ingredients)
        let paragraphs = steps.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // One step per line works too, when there are no blank lines at all.
        r.steps = paragraphs.count == 1 ? paragraphs[0].components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : paragraphs
        model.save(r)
    }

    func pickImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { setImage(u) }
    }

    func setImage(_ u: URL) {
        let dest = Store.imagesDir.appendingPathComponent("\(UUID().uuidString).\(u.pathExtension.isEmpty ? "jpg" : u.pathExtension)")
        if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { recipe.imagePath = dest.path }
    }
}

// MARK: Fix one ingredient

struct FixSheet: View {
    @ObservedObject var model: AppModel
    let recipe: Recipe
    let index: Int
    @State private var ing: Ingredient
    @State private var query = ""
    @State private var results: [Food] = []
    @State private var searching = false
    @State private var chosen: Food?
    @State private var grams = ""

    init(model: AppModel, recipe: Recipe, index: Int) {
        self.model = model; self.recipe = recipe; self.index = index
        let i = recipe.ingredients[index]
        _ing = State(initialValue: i)
        _query = State(initialValue: i.name.isEmpty ? i.line : i.name)
        _grams = State(initialValue: i.grams.map { Fmt.number($0, digits: 0) } ?? "")
    }

    var gramsValue: Double? { Double(grams.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ing.line).font(.title3.weight(.semibold))
                Label(ing.status.label + (ing.foodName.map { " · \($0)" } ?? ""), systemImage: ing.status.symbol)
                    .foregroundStyle(ing.status.color).font(.callout)
            }
            HStack {
                TextField("Hmotnosť", text: $grams).frame(width: 120)
                Text("g pre \(Fmt.number(recipe.servings)) porc.").foregroundStyle(.secondary)
                Spacer()
                if let n = (chosen?.per100 ?? ing.per100), let g = gramsValue {
                    Text("\(Fmt.kcal(n.kcal * g / 100)) · B \(Fmt.macro(n.protein * g / 100)) · T \(Fmt.macro(n.fat * g / 100)) · S \(Fmt.macro(n.carbs * g / 100))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Hľadať potravinu", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button("Hľadať", action: search).disabled(searching)
            }
            List(selection: Binding(get: { chosen?.id }, set: { id in chosen = results.first { $0.id == id } })) {
                if searching { Text("Hľadám v USDA a Open Food Facts…").foregroundStyle(.secondary) }
                ForEach(results) { f in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.displayName).lineLimit(1)
                            Text(f.source + (f.portions.first.map { " · \($0.label) = \(Fmt.grams($0.grams))" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(Fmt.number(f.per100.kcal.rounded(), digits: 0)) kcal · B \(Fmt.number(f.per100.protein)) / 100 g")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(f.id)
                }
            }
            .frame(height: 260)
            .cardBackground()
            if let c = chosen, !c.portions.isEmpty, let q = ing.qty {
                HStack {
                    Text("Porcie:").foregroundStyle(.secondary)
                    ForEach(c.portions.prefix(4), id: \.label) { p in
                        Button("\(p.label) (\(Fmt.grams(p.grams)))") { grams = Fmt.number(p.grams * q, digits: 0) }.buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
            HStack {
                Button("Nepočítať") { apply(skip: true) }.help("Voda, soľ podľa chuti, ozdoba…")
                Button("Analyzovať znova") { var r = recipe; r.ingredients[index].status = .pending; model.act { try model.store.save(r) }; model.sheet = nil; model.analyze(model.recipe(r.id) ?? r) }
                    .disabled(!AI.available)
                Spacer()
                SheetButtons(title: chosen == nil ? "Uložiť gramáž" : "Použiť", disabled: chosen == nil && (ing.per100 == nil || gramsValue == nil)) { apply(skip: false) }
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: search)
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        let store = model.store
        Task {
            let found = await Analyzer.candidates(q, store: store)
            results = found
            searching = false
            if chosen == nil, let ref = ing.foodRef { chosen = found.first { $0.id == ref } }
        }
    }

    func apply(skip: Bool) {
        var r = recipe
        var i = ing
        if skip {
            i.status = .skipped
        } else if let c = chosen {
            do { try Analyzer(store: model.store).use(c, for: &i, grams: gramsValue) } catch { model.error = error.localizedDescription; return }
        } else {
            i.grams = gramsValue
            i.status = .manual
        }
        r.ingredients[index] = i
        model.act { try model.store.save(r) }
        model.sheet = nil
    }
}

// MARK: Log a meal

struct LogMealSheet: View {
    @ObservedObject var model: AppModel
    let recipe: Recipe
    @State var servings: Double
    @State private var byGrams = false
    @State private var grams = 300.0
    @State private var date = Date()
    @State private var slot: MealSlot

    init(model: AppModel, recipe: Recipe, servings: Double) {
        self.model = model; self.recipe = recipe
        _servings = State(initialValue: servings)
        _grams = State(initialValue: (recipe.gramsPerServing * servings).rounded())
        let h = Calendar.current.component(.hour, from: Date())
        _slot = State(initialValue: h < 10 ? .breakfast : h < 15 ? .lunch : h < 17 ? .snack : .dinner)
    }

    var nutrients: Nutrients {
        byGrams && recipe.dishGrams > 0 ? recipe.total * (grams / recipe.dishGrams) : recipe.perServing * servings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Zjedol som: \(recipe.title)").font(.title2.weight(.semibold)).lineLimit(2)
            Picker("", selection: $byGrams) {
                Text("Porcie").tag(false)
                Text("Gramy").tag(true).disabled(recipe.dishGrams == 0)
            }
            .pickerStyle(.segmented).labelsHidden()
            Form {
                if byGrams {
                    TextField("Odvážené (g)", value: $grams, format: .number)
                    Text(recipe.yieldGrams == nil
                         ? "Hotové jedlo nie je odvážené, rátam so surovou hmotnosťou \(Fmt.grams(recipe.dishGrams)). Odváž hrniec a zadaj to v úprave receptu."
                         : "Celé jedlo váži \(Fmt.grams(recipe.dishGrams)).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Stepper(value: $servings, in: 0.25...20, step: 0.25) { Text("\(Fmt.qty(servings)) porc.") }
                }
                DatePicker("Deň", selection: $date, displayedComponents: .date)
                Picker("Jedlo", selection: $slot) { ForEach(MealSlot.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
            .formStyle(.grouped)
            .frame(height: 210)
            HStack(spacing: 14) {
                Text(Fmt.kcal(nutrients.kcal)).font(.title3.weight(.semibold)).foregroundStyle(Color.energy)
                ForEach(Macro.allCases, id: \.self) { m in Text("\(m.short) \(Fmt.macro(m.grams(nutrients)))").foregroundStyle(m.color) }
            }
            .monospacedDigit()
            SheetButtons(title: "Zapísať") {
                model.act {
                    try model.store.logMeal(recipe: recipe, grams: byGrams ? grams : nil, servings: byGrams ? nil : servings, date: Day.string(date), slot: slot)
                }
                model.sheet = nil
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: Plan a recipe

struct PlanSheet: View {
    @ObservedObject var model: AppModel
    @State var recipeId: Int64
    @State private var date: Date
    @State private var slot: MealSlot = .lunch
    @State private var servings: Double

    init(model: AppModel, recipe: Recipe?, date: String) {
        self.model = model
        let r = recipe ?? model.recipes.first
        _recipeId = State(initialValue: r?.id ?? 0)
        _date = State(initialValue: Day.date(date) ?? Date())
        _servings = State(initialValue: r?.servings ?? 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Naplánovať").font(.title2.weight(.semibold))
            Form {
                Picker("Recept", selection: $recipeId) {
                    ForEach(model.recipes.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) { Text($0.title).tag($0.id) }
                }
                DatePicker("Deň", selection: $date, displayedComponents: .date)
                Picker("Jedlo", selection: $slot) { ForEach(MealSlot.allCases, id: \.self) { Text($0.label).tag($0) } }
                Stepper(value: $servings, in: 1...30, step: 1) { Text("\(Fmt.number(servings)) porc.") }
            }
            .formStyle(.grouped)
            .frame(height: 230)
            SheetButtons(title: "Naplánovať", disabled: recipeId == 0) {
                var p = PlanItem()
                p.recipeId = recipeId; p.date = Day.string(date); p.slot = slot; p.servings = servings
                model.act { try model.store.save(p) }
                model.sheet = nil
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: recipeId) { _, id in if let r = model.recipe(id) { servings = r.servings } }
    }
}
