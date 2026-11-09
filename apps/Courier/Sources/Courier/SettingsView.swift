import CourierCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings().tabItem { Label("Účty", systemImage: "person.crop.circle") }
            SignaturesSettings().tabItem { Label("Podpisy", systemImage: "signature") }
            FolderSettings().tabItem { Label("Priečinky", systemImage: "folder") }
            NotificationSettings().tabItem { Label("Upozornenia", systemImage: "bell") }
        }
        .frame(width: 760, height: 520)
    }
}

/// Signatures: list on the left, editor on the right, default per account below.
struct SignaturesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selected) {
                        ForEach(model.signatures) { s in
                            Label(s.name, systemImage: s.isHTML ? "chevron.left.forwardslash.chevron.right" : "text.alignleft").tag(s.id)
                        }
                    }
                    .listStyle(.inset)
                    HStack(spacing: 0) {
                        Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }.disabled(selected == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless).padding(6)
                }
                .frame(minWidth: 190, maxWidth: 240)

                Group {
                    if let s = model.signatures.first(where: { $0.id == selected }) {
                        SignatureEditor(signature: s).id(s.id)
                    } else {
                        ContentUnavailableView("Žiadny podpis", systemImage: "signature", description: Text("Pridaj podpis tlačidlom +."))
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Form {
                Section("Predvolený podpis") {
                    ForEach(model.accounts) { a in
                        Picker(a.email, selection: Binding(get: { model.defaultSignatureID(account: a.id) },
                                                         set: { model.setDefaultSignature(account: a.id, $0) })) {
                            Text("Bez podpisu").tag(String?.none)
                            ForEach(model.signatures) { s in Text(s.name).tag(Optional(s.id)) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: min(220, 90 + CGFloat(model.accounts.count) * 32))
        }
        .onAppear { if selected == nil { selected = model.signatures.first?.id } }
    }

    func add() {
        let s = Signature(name: "Nový podpis", body: "S pozdravom\n\(model.accounts.first?.name ?? "")")
        model.save(s)
        selected = s.id
    }

    func remove() {
        guard let s = model.signatures.first(where: { $0.id == selected }) else { return }
        model.deleteSignature(s)
        selected = model.signatures.first?.id
    }
}

struct SignatureEditor: View {
    @EnvironmentObject var model: AppModel
    @State var signature: Signature

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Názov", text: $signature.name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Picker("", selection: $signature.isHTML) {
                    Text("Text").tag(false)
                    Text("HTML").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            TextEditor(text: $signature.body)
                .font(signature.isHTML ? .system(.body, design: .monospaced) : .body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
                .frame(minHeight: 120)
            Text("Náhľad").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Group {
                    if signature.isHTML { Text(AttributedString(htmlSnippet: signature.body) ?? AttributedString(signature.plain)) }
                    else { Text(signature.body) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: 140)
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            if signature.isHTML {
                Text("Tip: HTML podpis môže obsahovať odkazy a obrázky z webu (<img src=\"https://…\">). Príjemca dostane aj textovú verziu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .onChange(of: signature) { _, s in model.save(s) }
    }
}

/// Accounts: the name shown in the sidebar and used as sender name, server details, removing an account.
struct AccountsSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            ForEach(model.accounts) { a in
                Section {
                    AccountNameField(account: a)
                    LabeledContent("E-mail", value: a.email)
                    LabeledContent("Prijímanie", value: "\(a.imap.host):\(a.imap.port) · \(a.imap.security == .ssl ? "SSL/TLS" : "STARTTLS")")
                    if let smtp = a.smtp {
                        LabeledContent("Odosielanie", value: "\(smtp.host):\(smtp.port) · \(smtp.security == .ssl ? "SSL/TLS" : "STARTTLS")")
                    }
                    HStack {
                        Spacer()
                        Button("Odstrániť účet…", role: .destructive) {
                            let alert = NSAlert()
                            alert.messageText = "Odstrániť účet \(a.email)?"
                            alert.informativeText = "Z Courieru zmizne aj jeho lokálna kópia pošty a heslo z Keychainu. Na serveri sa nič nezmaže."
                            alert.addButton(withTitle: "Odstrániť")
                            alert.addButton(withTitle: "Zrušiť")
                            alert.buttons.first?.hasDestructiveAction = true
                            if alert.runModal() == .alertFirstButtonReturn { model.removeAccount(a) }
                        }
                    }
                } header: {
                    Text(a.name == a.email ? a.email : a.name)
                }
            }
            Section {
                Button("Pridať účet…") { model.showAddAccount = true }
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountNameField: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    @State private var name = ""

    var body: some View {
        TextField("Meno", text: $name, prompt: Text(account.email))
            .onAppear { name = account.name == account.email ? "" : account.name }
            .onSubmit { model.renameAccount(account, to: name) }
            .onDisappear { if name != (account.name == account.email ? "" : account.name) { model.renameAccount(account, to: name) } }
            .help("Zobrazuje sa v lište a ako meno odosielateľa")
    }
}

/// Which folder kinds show across all accounts at the top of the sidebar (all drafts, all sent, …).
struct FolderSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("thread.newestFirst") private var newestFirst = false
    var body: some View {
        Form {
            Section {
                Picker("Poradie správ vo vlákne", selection: $newestFirst) {
                    Text("Najstaršie hore (ako chat)").tag(false)
                    Text("Najnovšie hore").tag(true)
                }
            } header: {
                Text("Konverzácia")
            } footer: {
                Text("Prepína sa aj v menu Zobraziť.").foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: .constant(true)) { Label("Všetky doručené", systemImage: "tray.2") }.disabled(true)
                ForEach(AppModel.unifiedRoles, id: \.self) { r in
                    Toggle(isOn: Binding(get: { AppModel.unifiedShown(r) }, set: { model.setUnified(r, $0) })) {
                        Label(AppModel.unifiedTitle(r), systemImage: r.symbol)
                    }
                    .disabled(!model.availableRoles.contains(r))
                }
            } header: {
                Text("Spoločné priečinky v bočnom paneli")
            } footer: {
                Text("Každý ukáže daný priečinok zo všetkých schránok naraz. Sivé nemá žiadna schránka.").foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $model.showContactsTab) { Label("Adresár", systemImage: "person.crop.rectangle.stack") }
            } footer: {
                Text("Všetky kontakty z pošty (odosielatelia aj príjemcovia), hľadanie podľa mena alebo e-mailu. Otvorí sa aj cez ⇧⌘K.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
