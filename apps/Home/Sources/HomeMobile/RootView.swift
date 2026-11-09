#if os(iOS)
import HomeCore
import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(MobileCalendar.self) private var calendar
    @AppStorage("tab") private var tab = "today"

    var body: some View {
        Group {
            if !store.signedIn {
                SignInView()
            } else if store.household == nil {
                if store.needsHousehold { SetupView() } else {
                    ContentUnavailableView("Načítavam domácnosť", systemImage: "house", description: Text(store.error ?? "Spájam sa…"))
                }
            } else {
                TabView(selection: $tab) {
                    Tab("Dnes", systemImage: "sun.max.fill", value: "today") { NavigationStack { TodayTab() } }
                        .badge(store.openCount())
                    Tab("Úlohy", systemImage: "checklist", value: "tasks") { NavigationStack { TasksTab() } }
                    Tab("Nákup", systemImage: "cart.fill", value: "shopping") { NavigationStack { ShoppingTab() } }
                        .badge(store.shopping.filter { !$0.done }.count)
                    Tab("Byt", systemImage: "lightbulb.2.fill", value: "devices") { NavigationStack { DevicesTab() } }
                    Tab("Domácnosť", systemImage: "house.fill", value: "household") { NavigationStack { HouseholdTab() } }
                }
                // Asked only once signed in, not on the sign-in screen.
                .task { await calendar.load() }
            }
        }
    }
}

// MARK: Sign-in

struct SignInView: View {
    @Environment(Store.self) private var store
    @AppStorage("lastEmail") private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var linkSent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 76, height: 76)
                            .background(LinearGradient(colors: [Color(red: 0.66, green: 0.86, blue: 0.26), Color(red: 0.13, green: 0.52, blue: 0.24)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 18, style: .continuous))
                        Text("Úlohy, nákup a plány pre celú domácnosť.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("E-mail", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Heslo", text: $password).textContentType(.password).onSubmit(signIn)
                }
                Section {
                    Button(action: signIn) {
                        HStack { Spacer(); if working { ProgressView() } else { Text("Prihlásiť sa").bold() }; Spacer() }
                    }
                    .disabled(working || !email.contains("@") || password.isEmpty)
                    Button("Zabudnuté heslo? Pošli mi odkaz") {
                        run { try await store.sendSignInLink(email: email); linkSent = true }
                    }
                    .disabled(working || !email.contains("@"))
                } footer: {
                    if linkSent { Text("Odkaz je na ceste. Otvor e-mail na tomto iPhone a klikni naň, potom si v Domácnosti nastav nové heslo.") }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Home")
        }
    }

    func signIn() { run { try await store.signIn(email: email, password: password); password = "" } }

    func run(_ action: @escaping () async throws -> Void) {
        working = true; error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

struct SetupView: View {
    @Environment(Store.self) private var store
    @State private var name = ""
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tvoje meno v domácnosti") { TextField("Napr. Jana", text: $name) }
                Section {
                    TextField("Kód, napr. K7Q2PX", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Pridať sa") { run { try await store.joinHousehold(code: code, myName: name) } }
                        .disabled(code.count < 4 || name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                } header: { Text("Pridať sa k domácnosti") } footer: { Text("Kód je v Home u druhého člena, v Domácnosti.") }
                Section {
                    Button("Vytvoriť novú domácnosť") { run { try await store.createHousehold(myName: name) } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section { Button("Odhlásiť sa", role: .destructive) { store.signOut() } }
            }
            .navigationTitle("Vitaj")
        }
    }

    func run(_ action: @escaping () async throws -> Void) {
        working = true; error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

// MARK: Shared rows

struct WhoDot: View {
    let who: String
    var body: some View {
        Group {
            switch who {
            case Who.anyone: Image(systemName: "person.2.fill").font(.system(size: 10, weight: .bold))
            case Who.takeTurns: Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .bold))
            default: Text(String(who.prefix(1))).font(.system(size: 12, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(color.gradient, in: .circle)
    }
    var color: Color {
        switch who {
        case Who.anyone, Who.takeTurns: .gray
        default: [Color.blue, .pink, .orange, .teal, .purple][abs(who.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 5]
        }
    }
}

struct ChoreRow: View {
    @Environment(Store.self) private var store
    let due: Due
    var note: String?

    var body: some View {
        let done = store.isDone(due.task, on: due.day)
        Button {
            withAnimation(.snappy) { store.setDone(due.task, on: due.day, !done) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(done ? Color.leaf : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(due.task.title).strikethrough(done, color: .secondary).foregroundStyle(done ? .secondary : .primary)
                    Text(subtitle(done)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                WhoDot(who: due.who)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: done)
    }

    func subtitle(_ done: Bool) -> String {
        var parts = [note ?? due.task.repeatTitle]
        if done, let by = store.doneBy(due.task, on: due.day) { parts.append("spravil(a) \(by)") } else { parts.append(Who.title(due.who)) }
        return parts.joined(separator: " · ")
    }
}

struct SyncStatus: View {
    @Environment(Store.self) private var store
    var body: some View {
        if let e = store.error {
            Label("Nesynchronizované: \(e)", systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.orange)
        } else if store.pendingCount > 0 {
            Label("\(store.pendingCount) zmien čaká na odoslanie", systemImage: "arrow.triangle.2.circlepath.icloud").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
#endif
