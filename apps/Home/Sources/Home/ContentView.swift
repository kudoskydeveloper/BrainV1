import HomeCore
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(Events.self) private var events
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("section") private var saved = Section.today.rawValue

    var body: some View {
        @Bindable var app = app
        Group {
            if !store.signedIn {
                SignInView()
            } else if store.household == nil {
                if store.needsHousehold { SetupView() } else { loading }
            } else {
                NavigationSplitView {
                    Sidebar(selection: $app.section)
                        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
                } detail: {
                    VStack(spacing: 0) {
                        if let e = store.error {
                            Notice(symbol: "exclamationmark.triangle.fill", text: "Synchronizácia zlyhala: \(e). Zmeny sú uložené v Macu a odošlú sa neskôr.")
                                .padding([.horizontal, .top], 20)
                        }
                        detail
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { SyncButton() }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            Delegate.openMain = { [openWindow] in openWindow(id: "main") }
            if let s = Section(rawValue: saved) { app.section = s }
        }
        .onChange(of: app.section) { _, s in saved = s.rawValue }
        .task { await events.load() }
    }

    var loading: some View {
        ContentUnavailableView {
            Label("Načítavam domácnosť", systemImage: "house")
        } description: {
            Text(store.error ?? "Spájam sa so Supabase…")
        } actions: {
            if store.error != nil { Button("Skúsiť znova") { Task { await store.sync() } } } else { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder var detail: some View {
        switch app.section {
        case .today: TodayView()
        case .tasks: TasksView()
        case .shopping: ShoppingView()
        case .plan: PlanView()
        case .devices: DevicesView()
        case .household: HouseholdView()
        }
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var selection: Section

    var body: some View {
        List(selection: Binding<Section?>(get: { selection }, set: { if let s = $0 { selection = s } })) {
            SwiftUI.Section {
                row(.today, badge: store.openCount())
                row(.tasks, badge: 0)
                row(.shopping, badge: store.shopping.filter { !$0.done }.count)
                row(.plan, badge: 0)
            }
            SwiftUI.Section("Byt") {
                row(.devices, badge: 0)
            }
            SwiftUI.Section(store.household?.name ?? "Domov") {
                row(.household, badge: 0)
            }
        }
        .listStyle(.sidebar)
    }

    func row(_ s: Section, badge: Int) -> some View {
        Label { Text(s.title) } icon: { Image(systemName: s.symbol).foregroundStyle(s.color) }
            .badge(badge)
            .tag(s)
    }
}

/// Sync state in the toolbar: spinner while syncing, a count of changes waiting, otherwise the time of the last sync.
struct SyncButton: View {
    @Environment(Store.self) private var store
    var body: some View {
        Button { Task { await store.sync() } } label: {
            // A symbol, not ProgressView: the AppKit spinner flipping in and out every 30 s risks layout loops.
            if store.busy {
                Label("Synchronizujem", systemImage: "arrow.triangle.2.circlepath").symbolEffect(.rotate, isActive: true)
            } else if store.error != nil {
                Label("Nesynchronizované", systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
            } else {
                Label("Synchronizovať", systemImage: store.pendingCount > 0 ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud")
            }
        }
        .help(help)
    }
    var help: String {
        if store.pendingCount > 0 { return "\(store.pendingCount) zmien čaká na odoslanie (⌘R)" }
        if let t = store.lastSync { return "Synchronizované o \(t.formatted(date: .omitted, time: .shortened)) (⌘R)" }
        return "Synchronizovať (⌘R)"
    }
}

// MARK: Sign-in and household setup

struct SignInView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @AppStorage("lastEmail") private var email = ""
    @State private var password = ""
    @State private var linkSent = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "house.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(LinearGradient(colors: [Color(red: 0.66, green: 0.86, blue: 0.26), Color(red: 0.13, green: 0.52, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 22, style: .continuous))
            VStack(spacing: 6) {
                Text("Home").font(.largeTitle.weight(.semibold))
                Text("Úlohy, nákup a plány pre celú domácnosť.").foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                TextField("E-mail", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                SecureField("Heslo", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit(signIn)
                Button(action: signIn) {
                    Text(working ? "Prihlasujem…" : "Prihlásiť sa").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working || !email.contains("@") || password.isEmpty)
                Button("Zabudnuté heslo? Pošli mi odkaz na prihlásenie", action: sendLink)
                    .buttonStyle(.link)
                    .disabled(working || !email.contains("@"))
            }
            .frame(width: 320)
            if linkSent {
                Notice(symbol: "envelope.badge.fill", text: "Odkaz je na ceste na \(email). Klikni naň na tomto Macu a potom si v Domácnosti nastav nové heslo.",
                       tint: .blue)
                    .frame(maxWidth: 420)
            }
            if let e = error ?? app.linkError {
                Notice(symbol: "exclamationmark.triangle.fill", text: e).frame(maxWidth: 420)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func signIn() {
        guard email.contains("@"), !password.isEmpty, !working else { return }
        run { try await store.signIn(email: email, password: password); password = "" }
    }

    func sendLink() {
        run { try await store.sendSignInLink(email: email); linkSent = true }
    }

    func run(_ action: @escaping () async throws -> Void) {
        working = true; error = nil; app.linkError = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

struct SetupView: View {
    @Environment(Store.self) private var store
    @State private var name = NSFullUserName().components(separatedBy: " ").first ?? ""
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Vitaj").font(.largeTitle.weight(.semibold))
                Text("Prihlásený ako \(store.email ?? "")").foregroundStyle(.secondary)
            }
            TextField("Tvoje meno v domácnosti", text: $name).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack(alignment: .top, spacing: 16) {
                Card("Nová domácnosť", subtitle: "Si prvý. Ostatní sa pridajú tvojím kódom.") {
                    Button("Vytvoriť domácnosť") { run { try await store.createHousehold(myName: name) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                Card("Pridať sa", subtitle: "Kód je v Home u druhého člena, v Domácnosti.") {
                    HStack {
                        TextField("Kód, napr. K7Q2PX", text: $code).textFieldStyle(.roundedBorder).onSubmit(join)
                        Button("Pridať sa", action: join)
                            .disabled(code.count < 4 || name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    }
                }
            }
            .frame(maxWidth: 640)
            if let error { Notice(symbol: "exclamationmark.triangle.fill", text: error).frame(maxWidth: 640) }
            Button("Odhlásiť sa") { store.signOut() }.buttonStyle(.link)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func join() { run { try await store.joinHousehold(code: code, myName: name) } }

    func run(_ action: @escaping () async throws -> Void) {
        working = true; error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
