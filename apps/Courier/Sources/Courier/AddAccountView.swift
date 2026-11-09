import CourierCore
import SwiftUI

/// Like Thunderbird: name, e-mail and password; the server settings are found automatically. Manual IMAP only under "Rozšírené".
struct AddAccountView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var found: DiscoveredConfig?
    @State private var status = ""
    @State private var error: String?
    @State private var working = false
    @State private var advanced = false
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var imapSecurity = Security.ssl
    @State private var username = ""
    @State private var smtpHost = ""
    @State private var smtpPort = "465"

    var isGoogle: Bool { found?.imap.host.hasSuffix("gmail.com") == true }
    var isICloud: Bool { found?.imap.host.hasSuffix("mail.me.com") == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [Color(red: 0.25, green: 0.7, blue: 1), Color(red: 0.05, green: 0.3, blue: 0.85)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading) {
                    Text("Pridať e-mailový účet").font(.title2.weight(.semibold))
                    Text("Stačí e-mail a heslo, server nastavím sám.").foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Meno", text: $name, prompt: Text("Tvoje meno"))
                TextField("E-mail", text: $email, prompt: Text("meno@domena.sk"))
                    .textContentType(.emailAddress)
                    .onChange(of: email) { found = nil; error = nil }
                SecureField("Heslo", text: $password, prompt: Text(isGoogle ? "Heslo aplikácie" : (isICloud ? "Heslo pre aplikácie (xxxx-xxxx-xxxx-xxxx)" : "Heslo")))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 150)

            if let f = found {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(f.provider): IMAP \(f.imap.host):\(f.imap.port)").font(.callout)
                        Text("Nájdené cez \(f.source)").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                if isGoogle {
                    Text("Gmail: zadaj **heslo aplikácie** (Google účet → Zabezpečenie → Heslá aplikácií). Prihlásenie cez Google príde v ďalšej verzii.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Vytvoriť heslo aplikácie", destination: URL(string: "https://myaccount.google.com/apppasswords")!).font(.callout)
                }
                if isICloud {
                    Text("iCloud: zadaj **heslo pre aplikácie**, nie heslo k Apple ID (account.apple.com → Prihlásenie a zabezpečenie → Heslá pre aplikácie). Vyžaduje dvojfaktorové overenie.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Vytvoriť heslo pre aplikácie", destination: URL(string: "https://account.apple.com/account/manage")!).font(.callout)
                }
                if f.oauthOnly {
                    Text("Tento poskytovateľ (\(f.oauthProvider == .microsoft ? "Microsoft" : f.provider)) vyžaduje prihlásenie v prehliadači (OAuth). To pridám v ďalšej verzii.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            if !status.isEmpty, working { HStack { ProgressView().controlSize(.small); Text(status).foregroundStyle(.secondary) } }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }

            DisclosureGroup("Rozšírené (ručné nastavenie servera)", isExpanded: $advanced) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { Text("IMAP server"); TextField("imap.domena.sk", text: $imapHost) }
                    GridRow { Text("Port"); TextField("993", text: $imapPort).frame(width: 70) }
                    GridRow {
                        Text("Zabezpečenie")
                        Picker("", selection: $imapSecurity) { Text("SSL/TLS").tag(Security.ssl); Text("STARTTLS").tag(Security.starttls) }
                            .labelsHidden().fixedSize()
                    }
                    GridRow { Text("Používateľ"); TextField("celý e-mail", text: $username) }
                    GridRow { Text("SMTP server"); TextField("smtp.domena.sk", text: $smtpHost) }
                    GridRow { Text("SMTP port"); TextField("465", text: $smtpPort).frame(width: 70) }
                }
                .padding(.top, 8)
            }
            .font(.callout)

            HStack {
                Button("Zrušiť") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(working ? "Prihlasujem…" : "Prihlásiť") { Task { await submit() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !email.contains("@") || password.isEmpty || found?.oauthOnly == true && !advanced)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    func submit() async {
        working = true
        error = nil
        defer { working = false }
        let mail = email.trimmingCharacters(in: .whitespaces)
        var cfg: DiscoveredConfig
        if advanced, !imapHost.isEmpty {
            let imap = ServerConfig(host: imapHost, port: Int(imapPort) ?? 993, security: imapSecurity,
                                    username: username.isEmpty ? mail : username, auth: .password)
            let smtp = smtpHost.isEmpty ? nil : ServerConfig(host: smtpHost, port: Int(smtpPort) ?? 465, security: (Int(smtpPort) ?? 465) == 465 ? .ssl : .starttls,
                                                             username: username.isEmpty ? mail : username, auth: .password)
            cfg = DiscoveredConfig(provider: imapHost, source: "ručné nastavenie", imap: imap, smtp: smtp)
        } else if let f = found {
            cfg = f
        } else {
            status = "Hľadám nastavenia servera…"
            let log: @Sendable (String) -> Void = { s in Task { @MainActor in status = s } }
            guard let f = await Autoconfig.discover(email: mail, log: log) else {
                error = "Nastavenia pre \(mail.split(separator: "@").last ?? "") som nenašiel. Zadaj server v časti Rozšírené."
                advanced = true
                imapHost = "imap.\(mail.split(separator: "@").last ?? "")"
                return
            }
            found = f
            imapHost = f.imap.host; imapPort = String(f.imap.port); imapSecurity = f.imap.security; username = f.imap.username
            smtpHost = f.smtp?.host ?? ""; smtpPort = f.smtp.map { String($0.port) } ?? "465"
            cfg = f
            if f.oauthOnly { return }
        }
        // Providers that list OAuth first still accept a password (Gmail app passwords).
        cfg.imap.auth = .password
        cfg.smtp?.auth = .password
        status = "Prihlasujem sa na \(cfg.imap.host)…"
        do {
            // Google shows app passwords in groups ("abcd efgh ijkl mnop"); the server wants them without spaces.
            let google = cfg.imap.host.hasSuffix("gmail.com") || cfg.imap.host.hasSuffix("googlemail.com")
            let icloud = cfg.imap.host.hasSuffix("mail.me.com")
            let secret = google || icloud ? password.filter { !$0.isWhitespace } : password.trimmingCharacters(in: .newlines)
            if icloud && cfg.imap.username != mail {
                // iCloud takes the name part of an @icloud.com address, but an address on your own domain only as the full address.
                do { try await model.addAccount(email: mail, name: name, config: cfg, secret: secret) }
                catch MailError.auth {
                    cfg.imap.username = mail
                    try await model.addAccount(email: mail, name: name, config: cfg, secret: secret)
                }
            } else {
                try await model.addAccount(email: mail, name: name, config: cfg, secret: secret)
            }
            dismiss()
        } catch {
            let text = error.localizedDescription
            let google = cfg.imap.host.hasSuffix("gmail.com") || cfg.imap.host.hasSuffix("googlemail.com")
            if google && (text.contains("AUTHENTICATIONFAILED") || text.lowercased().contains("invalid credentials")) {
                self.error = "Google heslo neprijal. Treba heslo aplikácie (16 písmen), nie bežné heslo k Google účtu; vytvoríš ho odkazom vyššie, "
                    + "funguje len so zapnutým dvojstupňovým overením. Pri firemnom účte (Google Workspace) ich musí povoliť správca – ak sa ti v nastaveniach nezobrazujú, správca ich vypol."
            } else if cfg.imap.host.hasSuffix("mail.me.com") && error is MailError {
                self.error = "iCloud neprijal prihlásenie (\(text)). Treba heslo pre aplikácie z account.apple.com, nie heslo k Apple ID; "
                    + "a v Nastaveniach → iCloud → Pošta iCloud musí byť pošta zapnutá."
            } else if text.contains("AUTHENTICATIONFAILED") || text.lowercased().contains("invalid credentials") || text.lowercased().contains("authentication failed") {
                self.error = "Server odmietol e-mail alebo heslo. Skontroluj heslo (a či nemá na konci medzeru)."
            } else {
                self.error = text
            }
        }
    }
}

struct ProjectEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var project: Project
    @State private var senders = ""

    static let symbols = ["folder.fill", "briefcase.fill", "building.2.fill", "cart.fill", "star.fill", "heart.fill", "house.fill",
                          "person.2.fill", "chart.line.uptrend.xyaxis", "wineglass.fill", "hammer.fill", "graduationcap.fill",
                          "airplane", "banknote.fill", "megaphone.fill", "sparkles"]

    init(project: Project) {
        _project = State(initialValue: project)
        _senders = State(initialValue: project.sources.filter { $0.kind == .sender }.compactMap(\.pattern).joined(separator: ", "))
    }

    var isNew: Bool { !model.projects.contains { $0.id == project.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Názov", text: $project.name, prompt: Text("napr. Kudosky"))
                    LabeledContent("Farba") {
                        HStack(spacing: 6) {
                            ForEach(ProjectColor.allCases, id: \.self) { c in
                                Circle().fill(c.color).frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(.primary, lineWidth: project.color == c.rawValue ? 2 : 0).padding(-3))
                                    .onTapGesture { project.color = c.rawValue }
                            }
                        }
                    }
                    LabeledContent("Ikona") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26)), count: 8), spacing: 6) {
                            ForEach(Self.symbols, id: \.self) { s in
                                Image(systemName: s).frame(width: 26, height: 26)
                                    .background(project.symbol == s ? ProjectColor.of(project.color).opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                                    .onTapGesture { project.symbol = s }
                            }
                        }
                    }
                }
                Section("Schránky a priečinky") {
                    ForEach(model.accounts) { a in
                        Toggle(isOn: binding(.account, a.id, nil)) { Text("\(a.email) – doručená pošta") }
                        DisclosureGroup("Priečinky") {
                            ForEach((model.folders[a.id] ?? []).filter { $0.selectable && $0.role != .inbox }) { f in
                                Toggle(f.displayName, isOn: binding(.folder, a.id, f.path))
                            }
                        }
                        .font(.callout)
                    }
                }
                Section {
                    TextField("Odosielatelia alebo domény", text: $senders, prompt: Text("jan@firma.sk, @klient.sk"))
                } header: { Text("Odosielatelia") } footer: {
                    Text("Správy od týchto adries alebo domén z doručenej pošty všetkých schránok.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Odstrániť", role: .destructive) { model.delete(project); dismiss() }
                }
                Spacer()
                Button("Zrušiť") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Vytvoriť" : "Uložiť") { save() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
    }

    func binding(_ kind: ProjectSource.Kind, _ account: String, _ folder: String?) -> Binding<Bool> {
        let src = ProjectSource(kind: kind, accountID: account, folder: folder)
        return Binding(
            get: { project.sources.contains(src) },
            set: { on in
                project.sources.removeAll { $0 == src }
                if on { project.sources.append(src) }
            })
    }

    func save() {
        project.sources.removeAll { $0.kind == .sender }
        for s in senders.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            let p = s.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { project.sources.append(ProjectSource(kind: .sender, pattern: p)) }
        }
        project.name = project.name.trimmingCharacters(in: .whitespaces)
        model.save(project)
        model.selection = .project(project.id)
        dismiss()
    }
}
