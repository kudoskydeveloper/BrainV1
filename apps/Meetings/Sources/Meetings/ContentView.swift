import SwiftUI

/// What the sidebar can show.
enum Folder: Hashable {
    case upcoming
    case recordings(Business?)
}

/// What the middle list has selected.
enum Pick: Hashable {
    case upcoming(String)
    case recording(String)
}

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var folder: Folder? = .upcoming
    @State private var pick: Pick?
    @State private var query = ""
    @State private var toDelete: Recording?

    var body: some View {
        NavigationSplitView {
            Sidebar(data: store.data, selection: $folder)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            list
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            detail
        }
        .frame(minWidth: 960, minHeight: 560)
        .searchable(text: $query, placement: .toolbar, prompt: "Hľadať meeting alebo človeka")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.refresh() } label: {
                    if store.loading { ProgressView().controlSize(.small) } else { Label("Obnoviť", systemImage: "arrow.clockwise") }
                }
                .disabled(store.loading)
                .help(store.loading ? "Načítavam z Brainu…" : "Obnoviť (⌘R)")
            }
        }
        .onAppear {
            store.openMain = { [openWindow] in openWindow(id: "main") }
            selectDefault()
            applyPending()
        }
        .confirmationDialog("Vymazať nahrávku „\(toDelete?.title ?? "")“?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible, presenting: toDelete) { r in
            Button("Presunúť do Koša", role: .destructive) { delete(r) }
            Button("Zrušiť", role: .cancel) {}
        } message: { _ in
            Text("Poznámka z meetingu pôjde do Koša, odkiaľ ju vieš vrátiť. Vo Fathome nahrávka zostane.")
        }
        .onChange(of: folder) { _, _ in pick = nil; selectDefault() }
        .onChange(of: store.pendingSelection) { _, _ in applyPending() }
        .onChange(of: store.data?.generatedAt) { _, _ in if pick == nil { selectDefault() } }
    }

    @ViewBuilder var list: some View {
        if let d = store.data {
            switch folder ?? .upcoming {
            case .upcoming: UpcomingList(items: filter(d.upcoming), selection: $pick)
            case .recordings(let b): RecordingList(items: filter(d.recordings(b)), selection: $pick, title: b?.name ?? "Nahrávky",
                                                   onMove: move, onDelete: { toDelete = $0 })
            }
        } else if store.error != nil {
            Color.clear
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder var detail: some View {
        if let d = store.data {
            VStack(spacing: 0) {
                if let e = store.actionError { Notice(symbol: "exclamationmark.triangle.fill", text: e, tint: .red).padding([.horizontal, .top], 16) }
                if let e = store.error { Notice(symbol: "exclamationmark.triangle.fill", text: "Obnovenie zlyhalo, sú tu staršie dáta. \(e)").padding([.horizontal, .top], 16) }
                ForEach(d.sources.filter { !$0.value.ok }.map(\.key).sorted(), id: \.self) { k in
                    Notice(symbol: "bolt.horizontal.circle.fill", text: "\(k == "calendar" ? "Kalendár" : "Fathom") neodpovedá: \(d.sources[k]?.error ?? "")", tint: .red)
                        .padding([.horizontal, .top], 16)
                }
                switch pick {
                case .upcoming(let id):
                    if let u = d.upcoming.first(where: { $0.id == id }) { UpcomingDetail(u: u, store: store) } else { empty }
                case .recording(let path):
                    if let r = d.recordings.first(where: { $0.path == path }) {
                        RecordingDetail(r: r, busy: store.busy.contains(r.path), onMove: move, onDelete: { toDelete = $0 })
                    } else { empty }
                case nil: empty
                }
            }
        } else if let e = store.error {
            ContentUnavailableView {
                Label("Meetingy sa nepodarilo načítať", systemImage: "exclamationmark.triangle")
            } description: { Text(e) } actions: { Button("Skúsiť znova") { store.refresh() } }
        } else {
            ContentUnavailableView {
                Label("Načítavam", systemImage: "person.2.wave.2")
            } description: { Text("Kalendár a nahrávky z Fathomu cez Brain…") } actions: { ProgressView().controlSize(.small) }
        }
    }

    var empty: some View {
        ContentUnavailableView("Vyber meeting", systemImage: "person.2.wave.2", description: Text("Vľavo vyber meeting alebo nahrávku."))
    }

    func filter<T>(_ items: [T]) -> [T] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            switch item {
            case let u as Upcoming: return u.title.localizedCaseInsensitiveContains(q) || u.people.contains { $0.display.localizedCaseInsensitiveContains(q) || ($0.email ?? "").localizedCaseInsensitiveContains(q) }
            case let r as Recording: return r.title.localizedCaseInsensitiveContains(q) || r.people.contains { $0.display.localizedCaseInsensitiveContains(q) }
                || r.sections.contains { $0.items.contains { ($0.text ?? "").localizedCaseInsensitiveContains(q) } }
            default: return true
            }
        }
    }

    /// Moves a recording to another business; it stays selected (under its new path).
    func move(_ r: Recording, to b: Business) {
        Task {
            if let p = await store.move(r, to: b), pick == .recording(r.path) { pick = .recording(p) }
        }
    }

    /// Deletes a recording; if it was selected, the next one in the list is.
    func delete(_ r: Recording) {
        let shown: [Recording] = {
            guard let d = store.data, case .recordings(let b) = folder ?? .upcoming else { return [] }
            return filter(d.recordings(b)).sorted { $0.day > $1.day }
        }()
        let next = shown.firstIndex(of: r).flatMap { i in shown.indices.contains(i + 1) ? shown[i + 1] : i > 0 ? shown[i - 1] : nil }
        Task {
            if await store.delete(r), pick == .recording(r.path) { pick = next.map { .recording($0.path) } }
        }
    }

    /// The first meeting of the list, so the detail isn't empty when a folder opens.
    func selectDefault() {
        guard pick == nil, let d = store.data else { return }
        switch folder ?? .upcoming {
        case .upcoming: pick = d.upcoming.first.map { .upcoming($0.id) }
        case .recordings(let b): pick = d.recordings(b).first.map { .recording($0.path) }
        }
    }

    func applyPending() {
        guard let p = store.pendingSelection else { return }
        store.pendingSelection = nil
        switch p {
        case "recordings": folder = .recordings(nil)
        case "next":
            folder = .upcoming
            if let u = store.data?.upcoming.first { pick = .upcoming(u.id) }
        default: folder = .upcoming
        }
    }
}

struct Sidebar: View {
    let data: MeetingsData?
    @Binding var selection: Folder?

    var body: some View {
        List(selection: $selection) {
            Label { Text("Najbližšie") } icon: { Image(systemName: "calendar").foregroundStyle(.red) }
                .badge(today)
                .tag(Folder.upcoming)
            Section("Nahrávky") {
                Label { Text("Všetky") } icon: { Image(systemName: "waveform").foregroundStyle(.blue) }
                    .badge(data?.recordings.count ?? 0)
                    .tag(Folder.recordings(nil))
                ForEach(Business.allCases.filter { b in (data?.recordings(b).count ?? 0) > 0 }) { b in
                    Label { Text(b.name) } icon: { Image(systemName: b.symbol).foregroundStyle(b.color) }
                        .badge(data?.recordings(b).count ?? 0)
                        .tag(Folder.recordings(b))
                }
            }
        }
        .listStyle(.sidebar)
    }

    var today: Int { data?.upcoming.filter { Calendar.current.isDateInToday($0.startDate) }.count ?? 0 }
}
