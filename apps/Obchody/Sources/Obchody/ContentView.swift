import AppKit
import SwiftUI

/// Which client the inspector shows.
struct Pick: Hashable { let business: String; let account: String }

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var folder: Folder? = .today
    @State private var pick: Pick?
    @State private var query = ""
    @StateObject private var editing = Editing()

    var body: some View {
        NavigationSplitView {
            Sidebar(data: store.data, selection: $folder)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            main
                .inspector(isPresented: Binding(get: { pick != nil }, set: { if !$0 { pick = nil } })) {
                    if let pick { AccountInspector(pick: pick, store: store, data: store.data).id(pick) }
                }
                .inspectorColumnWidth(min: 340, ideal: 420, max: 560)
        }
        .frame(minWidth: 1040, minHeight: 620)
        .environmentObject(editing)
        .sheet(item: $editing.editor) { e in EditorSheet(editor: e, store: store) }
        .overlay(alignment: .bottom) { toastView }
        .searchable(text: $query, placement: .toolbar, prompt: "Hľadať klienta, obchod, úlohu")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(store.data?.businesses ?? []) { b in
                        Button("Nový klient v \(b.name)…") { editing.editor = .newAccount(b, lead: false) }
                        if b.id == "kudosky" { Button("Nový lead v Kudosky…") { editing.editor = .newAccount(b, lead: true) } }
                    }
                } label: { Label("Pridať", systemImage: "plus") }
                .help("Nový klient alebo lead")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.refresh() } label: {
                    if store.loading { ProgressView().controlSize(.small) } else { Label("Obnoviť", systemImage: "arrow.clockwise") }
                }
                .disabled(store.loading)
                .help(store.loading ? "Načítavam z 10T Base a Kuboardu…" : "Obnoviť (⌘R)")
            }
        }
        .onAppear {
            store.openMain = { [openWindow] in openWindow(id: "main") }
            applyPending()
            DispatchQueue.main.async { if store.pendingSelection == nil, folder != .today, folder == nil { folder = .today } }
        }
        .onChange(of: store.pendingSelection) { _, _ in applyPending() }
    }

    @ViewBuilder var main: some View {
        if let d = store.data {
            VStack(spacing: 0) {
                if let e = store.error {
                    Notice(symbol: "exclamationmark.triangle.fill", text: "Obnovenie zlyhalo, sú tu staršie dáta. \(e)").padding([.horizontal, .top], 16)
                }
                if let e = store.actionError {
                    Notice(symbol: "xmark.octagon.fill", text: "Zmena sa neuložila: \(e)", tint: .red).padding([.horizontal, .top], 16)
                        .onTapGesture { store.actionError = nil }
                }
                ForEach(d.businesses.filter { !$0.ok }) { b in
                    Notice(symbol: "bolt.horizontal.circle.fill", text: "\(b.name) neodpovedá: \(b.error ?? "")", tint: .red).padding([.horizontal, .top], 16)
                }
                switch folder ?? .today {
                case .today: TodayView(data: d, query: query, pick: $pick)
                case .pipeline(let id): if let b = d.business(id) { PipelineBoard(b: b, query: query, pick: $pick) }
                case .accounts(let id): if let b = d.business(id) { AccountsTable(b: b, query: query, pick: $pick) }
                case .tasks(let id): if let b = d.business(id) { TasksView(b: b, query: query, pick: $pick) }
                case .leads(let id): if let b = d.business(id) { LeadsTable(b: b, query: query, pick: $pick) }
                }
            }
        } else if let e = store.error {
            ContentUnavailableView {
                Label("Obchody sa nepodarilo načítať", systemImage: "exclamationmark.triangle")
            } description: { Text(e) } actions: { Button("Skúsiť znova") { store.refresh() } }
        } else {
            ContentUnavailableView {
                Label("Načítavam", systemImage: "building.2")
            } description: { Text("10T Base a Kuboard cez Brain…") } actions: { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder var toastView: some View {
        if let t = store.toast {
            Label(t, systemImage: "checkmark.circle.fill")
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 18)
                .task(id: t) {
                    try? await Task.sleep(for: .seconds(3))
                    if store.toast == t { store.toast = nil }
                }
        }
    }

    func applyPending() {
        guard let p = store.pendingSelection else { return }
        store.pendingSelection = nil
        folder = Folder(p) ?? .today
    }
}

struct Sidebar: View {
    let data: Overview?
    @Binding var selection: Folder?

    var body: some View {
        List(selection: $selection) {
            Label { Text("Dnes") } icon: { Image(systemName: "sun.max.fill").foregroundStyle(.orange) }
                .badge(dueCount)
                .tag(Folder.today)
            ForEach(data?.businesses ?? []) { b in
                Section(b.name) {
                    row("Pipeline", "rectangle.split.3x1.fill", b.tint, b.openDeals.count, .pipeline(b.id))
                    if b.id == "kudosky" { row("Leady", "person.crop.circle.badge.plus", .green, b.leads.count, .leads(b.id)) }
                    row("Klienti", "building.2.fill", .blue, b.accounts.count, .accounts(b.id))
                    row("Úlohy", "checklist", .purple, b.tasks.count, .tasks(b.id))
                }
            }
        }
        .listStyle(.sidebar)
    }

    var dueCount: Int {
        let today = Calendar.current.startOfDay(for: .now)
        return data?.businesses.flatMap(\.tasks).filter { $0.due.flatMap(Fmt.day).map { $0 <= today } ?? false }.count ?? 0
    }

    func row(_ title: String, _ symbol: String, _ tint: Color, _ badge: Int, _ tag: Folder) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .badge(badge)
            .tag(tag)
    }
}

/// Case- and diacritics-insensitive "every word appears".
func matches(_ query: String, _ text: String) -> Bool {
    let fold = { (s: String) in s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
    let hay = fold(text)
    return fold(query).split(separator: " ").allSatisfy { hay.contains($0) }
}
