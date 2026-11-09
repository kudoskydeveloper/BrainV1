import AppKit
import HomeCore
import SwiftUI

struct HouseholdView: View {
    @Environment(Store.self) private var store
    @State private var name = ""
    @State private var error: String?
    @State private var copied = false
    @State private var newPassword = ""
    @State private var passwordSaved = false

    var body: some View {
        Page {
            Text("Domácnosť").font(.largeTitle.weight(.semibold))
            if let h = store.household {
                Card("Názov") {
                    HStack {
                        TextField("Názov domácnosti", text: $name).textFieldStyle(.roundedBorder).onSubmit(rename)
                        Button("Uložiť", action: rename).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == h.name)
                    }
                }
                Card("Členovia", subtitle: "Každý vidí a mení tie isté úlohy a nákup") {
                    Rows(items: h.members.map { MemberItem(m: $0) }, inset: 40) { item in
                        HoverRow {
                            WhoBadge(who: item.m.name)
                            Text(item.m.name)
                            if item.m.name == store.me { Text("ty").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }
                    }
                }
                Card("Pozvať", subtitle: "Druhý člen sa prihlási svojím e-mailom a v Home zadá tento kód") {
                    HStack(spacing: 14) {
                        Text(h.inviteCode)
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copied ? "Skopírované" : "Kopírovať") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(h.inviteCode, forType: .string)
                            copied = true
                        }
                        Spacer()
                    }
                    Text("Jeho účet treba najprv pridať v Supabase (Authentication › Users › Add user, s heslom), registrácia je zatvorená.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Card("Účet") {
                LabeledContent("Prihlásený", value: store.email ?? "–")
                LabeledContent("Synchronizácia", value: syncText)
                HStack {
                    SecureField("Nové heslo (aspoň 6 znakov)", text: $newPassword).textFieldStyle(.roundedBorder).onSubmit(savePassword)
                    Button(passwordSaved ? "Uložené" : "Zmeniť heslo", action: savePassword).disabled(newPassword.count < 6)
                }
                Button("Odhlásiť sa") { store.signOut() }
            }
            if let error { Notice(symbol: "exclamationmark.triangle.fill", text: error) }
        }
        .onAppear { name = store.household?.name ?? "" }
    }

    struct MemberItem: Identifiable { let m: Member; var id: String { m.userId } }

    var syncText: String {
        if store.pendingCount > 0 { return "\(store.pendingCount) zmien čaká" }
        guard let t = store.lastSync else { return "zatiaľ nie" }
        return "o \(t.formatted(date: .omitted, time: .shortened))"
    }

    func savePassword() {
        let p = newPassword
        Task {
            do { try await store.setPassword(p); newPassword = ""; passwordSaved = true; error = nil } catch { self.error = error.localizedDescription }
        }
    }

    func rename() {
        let n = name
        Task {
            do { try await store.renameHousehold(n); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}
