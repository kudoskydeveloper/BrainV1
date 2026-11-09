#if os(iOS)
import SwiftUI
import CourierCore

/// New message or reply. Plain text; signature and the quote come from the account defaults.
struct ComposeView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let reply: MessageSummary?

    @State private var accountID = ""
    @State private var to = ""
    @State private var subject = ""
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if model.accounts.count > 1 {
                    Picker("Od", selection: $accountID) {
                        ForEach(model.accounts) { Text($0.email).tag($0.id) }
                    }
                }
                TextField("Komu", text: $to).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Predmet", text: $subject)
                TextEditor(text: $text).frame(minHeight: 260)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle(reply == nil ? "Nová správa" : "Odpoveď")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zrušiť", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else {
                        Button { Task { await send() } } label: { Image(systemName: "arrow.up") }
                            .disabled(to.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    func prefill() {
        accountID = reply?.accountID ?? model.accounts.first?.id ?? ""
        guard let r = reply else { return }
        to = r.fromAddress
        subject = r.subject.lowercased().hasPrefix("re:") ? r.subject : "Re: \(r.subject)"
    }

    func send() async {
        let recipients = to.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { EmailAddress(name: "", address: $0) }
        var body = text
        if let sig = model.store.defaultSignature(account: accountID), !sig.isEmpty { body += "\n\n-- \n" + sig }
        var m = OutgoingMessage(accountID: accountID, to: recipients, subject: subject, body: body)
        if let r = reply {
            let h = model.replyHeaders(r)
            m.inReplyTo = h.inReplyTo
            m.references = h.references
            if let b = model.store.body(id: r.id)?.text {
                let quote = b.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                m.body += "\n\n\(r.date.formatted(date: .abbreviated, time: .shortened)), \(r.fromDisplay) napísal(a):\n\(quote)"
            }
        }
        sending = true
        defer { sending = false }
        do { try await model.send(m); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct SettingsView: View {
    @Environment(MobileModel.self) private var model
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section("Schránky") {
                    ForEach(model.accounts) { a in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.name == a.email ? a.email : a.name).font(.body)
                            if a.name != a.email { Text(a.email).font(.caption).foregroundStyle(.secondary) }
                            Text(a.imap.host).font(.caption2).foregroundStyle(.tertiary)
                            if let e = model.accountErrors[a.id] {
                                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .swipeActions { Button("Odstrániť", role: .destructive) { model.removeAccount(a) } }
                    }
                    Button { adding = true } label: { Label("Pridať účet", systemImage: "plus") }
                }
                Section {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        HStack {
                            Label("Skontrolovať poštu", systemImage: "arrow.clockwise")
                            Spacer()
                            if model.refreshing { ProgressView() }
                        }
                    }
                    .disabled(model.refreshing)
                } footer: {
                    Text("Pošta, projekty a štítky sa ukladajú len v tomto iPhone. Heslá sú v Keychaine.")
                }
            }
            .navigationTitle("Nastavenia")
            .sheet(isPresented: $adding) { AddAccountView() }
        }
    }
}

struct AddAccountView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var working = false
    @State private var log: [String] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("E-mail", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.emailAddress)
                    TextField("Meno (nepovinné)", text: $name).textContentType(.name)
                    SecureField("Heslo alebo heslo pre aplikácie", text: $password).textContentType(.password)
                } footer: {
                    Text("Gmail a iCloud chcú heslo pre aplikácie, nie bežné heslo.")
                }
                if !log.isEmpty {
                    Section("Priebeh") { ForEach(Array(log.enumerated()), id: \.offset) { Text($0.element).font(.caption) } }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            }
            .navigationTitle("Nový účet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zrušiť", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Pridať") { Task { await add() } }.disabled(!email.contains("@") || password.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    func add() async {
        working = true; error = nil; log = []
        defer { working = false }
        do {
            try await model.addAccount(email: email, name: name, secret: password) { line in
                Task { @MainActor in log.append(line) }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
#endif
