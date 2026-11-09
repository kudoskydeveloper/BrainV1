import SwiftUI

/// What the sidebar can show.
enum Section: Hashable {
    case summary
    case sport(Sport)
    case nutrition
    case weight
}

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("section") private var saved = "summary"
    @State private var section: Section? = .summary
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            Sidebar(o: store.overview, selection: $section)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: Overview.Exercise.self) { e in ExerciseView(e: e) }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Obdobie", selection: $store.days) {
                    Text("Týždeň").tag(7)
                    Text("Mesiac").tag(30)
                    Text("3 mesiace").tag(90)
                    Text("Rok").tag(365)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Obdobie prehľadu")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.refresh() } label: {
                    if store.loading { ProgressView().controlSize(.small) } else { Label("Obnoviť", systemImage: "arrow.clockwise") }
                }
                .disabled(store.loading)
                .help(store.loading ? "Načítavam z Hevy, Stravy a MyFitnessPal…" : "Obnoviť (⌘R)")
            }
        }
        .onAppear {
            store.openMain = { [openWindow] in openWindow(id: "main") }
            section = Self.decode(saved)
        }
        .onChange(of: section) { _, s in
            path = NavigationPath()
            saved = Self.encode(s ?? .summary)
        }
    }

    @ViewBuilder var detail: some View {
        if let o = store.overview {
            VStack(spacing: 0) {
                Banners(o: o, error: store.error)
                switch section ?? .summary {
                case .summary: SummaryView(o: o, section: $section)
                case .sport(.strength): StrengthView(o: o)
                case .sport(let s): SportView(o: o, sport: s)
                case .nutrition: NutritionView(o: o)
                case .weight: WeightView(o: o)
                }
            }
        } else if let e = store.error {
            ContentUnavailableView {
                Label("Dáta sa nepodarilo načítať", systemImage: "exclamationmark.triangle")
            } description: { Text(e) } actions: {
                Button("Skúsiť znova") { store.refresh() }
            }
        } else {
            ContentUnavailableView {
                Label("Načítavam", systemImage: "figure.run")
            } description: {
                Text("Hevy, Strava a MyFitnessPal cez Brain…")
            } actions: { ProgressView().controlSize(.small) }
        }
    }

    static func encode(_ s: Section) -> String {
        switch s {
        case .summary: "summary"
        case .sport(let sp): "sport." + sp.rawValue
        case .nutrition: "nutrition"
        case .weight: "weight"
        }
    }
    static func decode(_ s: String) -> Section {
        if s.hasPrefix("sport."), let sp = Sport(rawValue: String(s.dropFirst(6))) { return .sport(sp) }
        return ["nutrition": .nutrition, "weight": .weight][s] ?? .summary
    }
}

/// Problems shown above every page: a failed refresh (older data shown) and sources that didn't answer.
struct Banners: View {
    let o: Overview
    let error: String?
    var body: some View {
        let failed = o.failed
        if error != nil || !failed.isEmpty {
            VStack(spacing: 6) {
                if let error {
                    Notice(symbol: "exclamationmark.triangle.fill", text: "Obnovenie zlyhalo, sú tu dáta z \(Fmt.time(updated)). \(error)")
                }
                ForEach(failed, id: \.name) { f in
                    Notice(symbol: "bolt.horizontal.circle.fill", text: "\(f.name) neodpovedá: \(f.error)", tint: .red)
                }
            }
            .padding([.horizontal, .top], 20)
        }
    }
    var updated: Date { ISO8601DateFormatter().date(from: String(o.generatedAt.prefix(19)) + "Z") ?? .now }
}

struct Sidebar: View {
    let o: Overview?
    @Binding var selection: Section?

    var body: some View {
        List(selection: $selection) {
            Label("Prehľad", systemImage: "square.grid.2x2").tag(Section.summary)

            SwiftUI.Section("Športy") {
                ForEach(sports) { s in
                    Label { Text(s.name) } icon: { Image(systemName: s.symbol).foregroundStyle(s.color) }
                        .badge(count(s))
                        .tag(Section.sport(s))
                }
            }

            SwiftUI.Section("Zdravie") {
                Label { Text("Výživa") } icon: { Image(systemName: "fork.knife").foregroundStyle(.red) }.tag(Section.nutrition)
                Label { Text("Váha") } icon: { Image(systemName: "scalemass.fill").foregroundStyle(.purple) }.tag(Section.weight)
            }
        }
        .listStyle(.sidebar)
    }

    /// Sports with something in the period; strength always (its exercises go back a year).
    var sports: [Sport] {
        Sport.allCases.filter { $0 == .strength || (o?.sport($0)?.sessions ?? 0) > 0 }
    }
    func count(_ s: Sport) -> Int { Int(o?.sport(s)?.sessions ?? 0) }
}
