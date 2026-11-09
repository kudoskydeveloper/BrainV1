import AppKit
import ReceptyCore
import SwiftUI

/// What the sidebar shows.
enum Page: Hashable {
    case all, favorites, recent
    case tag(String)
    case author(String)
    case plan, log, shopping
}

/// A sheet the window shows.
enum Sheet: Identifiable {
    case importer
    case edit(Recipe)
    case fix(Recipe, Int)
    case logMeal(Recipe, Double)
    case planRecipe(Recipe?, String)
    case photos(Int64, Int)
    var id: String {
        switch self {
        case .importer: "import"
        case .edit(let r): "edit\(r.id)"
        case .fix(let r, let i): "fix\(r.id)-\(i)"
        case .logMeal(let r, _): "log\(r.id)"
        case .planRecipe(let r, let d): "plan\(r?.id ?? 0)\(d)"
        case .photos(let id, let n): "photos\(id)-\(n)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: Store
    @Published var recipes: [Recipe] = []
    @Published var tags: [String] = []
    /// Who recipes are from (Od koho), most recipes first.
    @Published var authors: [String] = []
    @Published var page: Page? = .all
    /// Recipes opened in the detail column (a stack, so Back works).
    @Published var path: [Int64] = []
    @Published var sheet: Sheet?
    @Published var error: String?
    @Published var search = ""
    /// Analysis or import running, per recipe id (0 = an import), with what it's doing.
    @Published var busy: [Int64: String] = [:]
    /// Bumped on every reload so pages that compute from the store refresh.
    @Published var version = 0
    var openMain: (() -> Void)?
    var openCook: ((Int64) -> Void)?
    private var seenVersion = -1
    private var poll: Timer?

    init() {
        do { store = try Store() } catch { fatalError("Recepty: databáza sa nedá otvoriť: \(error)") }
        reload()
        // recepty-mcp (Brain) writes to the same database: pick its changes up.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let m = AppModel.shared
                if m.store.dataVersion != m.seenVersion { m.reload() }
            }
        }
    }

    func reload() {
        seenVersion = store.dataVersion
        recipes = store.recipes()
        tags = store.allTags()
        authors = store.allAuthors()
        version += 1
        path = path.filter { id in recipes.contains { $0.id == id } }
        if case .tag(let t) = page, !tags.contains(t) { page = .all }
        if case .author(let a) = page, !authors.contains(a) { page = .all }
    }

    func act(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = error.localizedDescription }
        reload()
    }

    func recipe(_ id: Int64) -> Recipe? { recipes.first { $0.id == id } }

    var visible: [Recipe] {
        var list = recipes
        switch page ?? .all {
        case .favorites: list = list.filter(\.favorite)
        case .recent: list = list.filter { $0.lastCooked != nil }.sorted { ($0.lastCooked ?? "") > ($1.lastCooked ?? "") }
        case .tag(let t): list = list.filter { $0.tags.contains(t) }
        case .author(let a): list = list.filter { $0.author == a }
        default: break
        }
        let words = fold(search).split(separator: " ").map(String.init)
        if !words.isEmpty {
            list = list.filter { r in
                let hay = fold(([r.title, r.author] + r.tags + r.ingredients.map(\.line)).joined(separator: " "))
                return words.allSatisfy { hay.contains($0) }
            }
        }
        return list
    }

    func open(_ id: Int64) {
        switch page ?? .all {
        case .plan, .log, .shopping: page = .all
        default: break
        }
        path = [id]
    }

    // MARK: Work with the model

    func importRecipe(url: String? = nil, text: String? = nil, images: [URL] = [], author: String = "") {
        guard busy[0] == nil else { return }
        busy[0] = "Začínam…"
        let store = store
        Task {
            do {
                let progress: @Sendable (String) -> Void = { s in Task { @MainActor in AppModel.shared.busy[0] = s } }
                let imp = Importer(store: store)
                var r = !images.isEmpty ? try await imp.fromImages(images, progress: progress)
                    : url != nil ? try await imp.fromURL(url!, progress: progress) : try await imp.fromText(text ?? "", progress: progress)
                let who = author.trimmingCharacters(in: .whitespaces)
                if !who.isEmpty { r.author = who }
                r = try store.save(r)
                busy[0] = nil
                reload()
                sheet = nil
                open(r.id)
                analyze(r)
            } catch {
                busy[0] = nil
                self.error = error.localizedDescription
            }
        }
    }

    func analyze(_ r: Recipe, all: Bool = false) {
        guard busy[r.id] == nil else { return }
        busy[r.id] = "Analyzujem…"
        let store = store, id = r.id
        Task {
            do {
                let progress: @Sendable (String) -> Void = { s in Task { @MainActor in AppModel.shared.busy[id] = s } }
                _ = try await Analyzer(store: store).analyze(r, all: all, progress: progress)
            } catch { self.error = "Analýza „\(r.title)“: \(error.localizedDescription)" }
            busy[id] = nil
            reload()
        }
    }

    /// Saves an edited recipe and analyses the lines that are new.
    func save(_ r: Recipe) {
        do {
            let saved = try store.save(r)
            reload()
            sheet = nil
            if !path.contains(saved.id) { open(saved.id) }
            if saved.needsAnalysis { analyze(saved) }
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ r: Recipe) {
        let a = NSAlert()
        a.messageText = "Zmazať recept „\(r.title)“?"
        a.informativeText = "Zjedené porcie v denníku zostanú."
        a.addButton(withTitle: "Zmazať").hasDestructiveAction = true
        a.addButton(withTitle: "Zrušiť")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        act { try store.delete(recipe: r.id) }
    }

    /// Adds photos of the original to a recipe's archive; their text is read in the background (Brain's OCR).
    func addPhotos(_ files: [URL], to r: Recipe) {
        guard !files.isEmpty else { return }
        let store = store, id = r.id
        Task {
            var photos: [SourcePhoto] = []
            for f in files {
                let t = Importer.extractPath == nil ? "" : ((try? await Importer.ocr(f)) ?? "")
                    .replacingOccurrences(of: #"^\[image[^\]]*\]\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                photos.append(SourcePhoto(path: f.path, text: t))
            }
            do { try store.addPhotos(photos, to: id) } catch { self.error = error.localizedDescription }
            reload()
        }
    }

    func pickPhotos(for r: Recipe) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        p.message = "Fotky originálu receptu (strana z knihy, rukopis)"
        if p.runModal() == .OK { addPhotos(p.urls, to: r) }
    }

    func toggleFavorite(_ r: Recipe) { act { try store.setFavorite(r.id, !r.favorite) } }

    func cook(_ r: Recipe) { openCook?(r.id) }
}
