import CourierCore
import SwiftUI
import UniformTypeIdentifiers

/// An open composer window's content.
struct ComposeDraft: Identifiable, Hashable {
    var id = UUID()
    var accountID: String
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    /// The original message for replies and forwards, kept below the signature (shown collapsed in the composer).
    var quoted = ""
    var signatureID: String?
    var inReplyTo: String?
    var references: [String] = []
    var attachments: [URL] = []
    var messageID = "\(UUID().uuidString.lowercased())@courier.local"
    var showCcBcc = false
    var sent = false
    /// Set when the draft came from a scheduled message: closing keeps it scheduled.
    var scheduledAt: Date?

    init(accountID: String, signatureID: String? = nil) {
        self.accountID = accountID
        self.signatureID = signatureID
    }

    /// Same content under a new window id (after undo).
    init(copying d: ComposeDraft) {
        self = d
        id = UUID()
    }

    /// Back from the outbox: the stored body already has signature and quote in it.
    init(from m: OutgoingMessage) {
        accountID = m.accountID
        to = m.to.map(\.full).joined(separator: ", ")
        cc = m.cc.map(\.full).joined(separator: ", ")
        bcc = m.bcc.map(\.full).joined(separator: ", ")
        subject = m.subject
        body = m.composerText ?? m.body
        quoted = m.quoted ?? ""
        signatureID = m.signatureID
        inReplyTo = m.inReplyTo
        references = m.references
        attachments = m.attachments
        messageID = m.messageID
        showCcBcc = !m.cc.isEmpty || !m.bcc.isEmpty
    }

    var isEmpty: Bool { to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func outgoing(signature: Signature?) -> OutgoingMessage {
        var m = OutgoingMessage(accountID: accountID, to: MIME.parseAddresses(to), cc: MIME.parseAddresses(cc), bcc: MIME.parseAddresses(bcc),
                                subject: subject, body: body, inReplyTo: inReplyTo, references: references, attachments: attachments)
        m.messageID = messageID
        m.compose(text: body, signature: signature, quoted: quoted)
        m.composerText = body
        m.quoted = quoted
        m.signatureID = signature?.id
        return m
    }
}

extension AppModel {
    func newDraft(account: String? = nil) -> UUID {
        var acc = account
        if acc == nil, case .folder(let a, _) = selection { acc = a }
        let id = acc ?? accounts.first?.id ?? ""
        let d = ComposeDraft(accountID: id, signatureID: defaultSignatureID(account: id))
        drafts[d.id] = d
        return d.id
    }

    enum ReplyKind { case reply, replyAll, forward }

    func replyDraft(_ m: MessageSummary, _ kind: ReplyKind) -> UUID {
        guard let a = account(m.accountID) else { return newDraft() }
        var d = ComposeDraft(accountID: a.id, signatureID: defaultSignatureID(account: a.id))
        let me = a.email.lowercased()
        let body = bodies[m.id] ?? store.body(id: m.id)
        let original = (body?.text ?? body?.html.map(MIME.stripHTML) ?? m.snippet).trimmingCharacters(in: .whitespacesAndNewlines)
        let when = m.date.formatted(date: .long, time: .shortened)
        let sender = m.fromName.isEmpty ? m.fromAddress : "\(m.fromName) <\(m.fromAddress)>"
        func prefixed(_ p: String) -> String {
            let s = m.subject
            return s.lowercased().hasPrefix(p.lowercased()) ? s : "\(p) \(s)"
        }
        switch kind {
        case .reply, .replyAll:
            let fromMe = m.fromAddress.lowercased() == me
            let toList = MIME.parseAddresses(m.to)
            let primary: [EmailAddress] = fromMe ? toList : [EmailAddress(name: m.fromName, address: m.fromAddress)]
            d.to = primary.map(\.full).joined(separator: ", ")
            if kind == .replyAll {
                let skip = Set(primary.map { $0.address.lowercased() } + [me])
                var seen = Set<String>()
                let others = (toList + MIME.parseAddresses(body?.cc ?? "")).filter {
                    let k = $0.address.lowercased()
                    return !skip.contains(k) && seen.insert(k).inserted
                }
                d.cc = others.map(\.full).joined(separator: ", ")
                d.showCcBcc = !others.isEmpty
            }
            d.subject = prefixed("Re:")
            let h = store.threadHeaders(id: m.id)
            if !h.messageID.isEmpty {
                d.inReplyTo = h.messageID
                d.references = h.references + [h.messageID]
            }
            let quoted = original.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            d.quoted = "Dňa \(when) \(sender) napísal(a):\n\(quoted)"
        case .forward:
            d.subject = prefixed("Fwd:")
            d.quoted = "---------- Preposlaná správa ----------\nOd: \(sender)\nDátum: \(when)\nPredmet: \(m.subject)\nKomu: \(m.to)\n\n\(original)"
        }
        drafts[d.id] = d
        return d.id
    }

    func saveDraft(_ id: UUID) async throws {
        guard let d = drafts[id], !d.sent, !d.isEmpty else { return }
        try await sync.saveDraft(d.outgoing(signature: signatures.first { $0.id == d.signatureID }))
        reload()
    }
}

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(\.openSettings) var openSettings
    let id: UUID
    @State private var error: String?
    @State private var note = ""
    @State private var importing = false
    @State private var showQuote = false
    @State private var scheduling = false
    @State private var scheduleDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @FocusState private var focus: Field?
    enum Field: Hashable { case to, cc, bcc, subject, body }

    var draft: Binding<ComposeDraft> {
        Binding(get: { model.drafts[id] ?? ComposeDraft(accountID: model.accounts.first?.id ?? "") },
                set: { model.drafts[id] = $0 })
    }
    var d: ComposeDraft { draft.wrappedValue }
    var canSend: Bool { !MIME.parseAddresses(d.to + "," + d.cc + "," + d.bcc).isEmpty }
    var signature: Signature? { model.signatures.first { $0.id == d.signatureID } }

    var body: some View {
        VStack(spacing: 0) {
            fields
            if let at = d.scheduledAt { scheduledBanner(at) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: draft.body)
                        .font(.body)
                        .scrollDisabled(true)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .focused($focus, equals: .body)
                    if let s = signature { signatureView(s) }
                    if !d.quoted.isEmpty { quoteView }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            if !d.attachments.isEmpty { attachmentsBar }
            bottomBar
        }
        .navigationTitle(d.subject.isEmpty ? "Nová správa" : d.subject)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { sendButton }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { addFiles(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in addFiles([url]) } }
                }
            }
            return true
        }
        .frame(minWidth: 600, minHeight: 480)
        .onAppear {
            // Windows restored by macOS after a relaunch point at drafts that no longer exist: close them.
            guard model.drafts[id] != nil else { dismissWindow(); return }
            focus = d.to.isEmpty ? .to : .body
        }
        .onDisappear {
            // A scheduled message being edited goes back to the outbox at its time; anything else unsent becomes a server draft.
            if let d = model.drafts[id], !d.sent, let at = d.scheduledAt {
                try? model.queue(id, at: max(at, Date().addingTimeInterval(AppModel.undoSeconds)), quiet: true)
                model.drafts[id] = nil
            } else if let d = model.drafts[id], !d.sent, !d.isEmpty { Task { try? await model.saveDraft(id); model.drafts[id] = nil } } else { model.drafts[id] = nil }
        }
    }

    // MARK: Parts

    var fields: some View {
        VStack(spacing: 0) {
            row("Od") {
                Picker("", selection: draft.accountID) {
                    ForEach(model.accounts) { a in Text(a.name == a.email ? a.email : "\(a.name) <\(a.email)>").tag(a.id) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: d.accountID) { _, new in draft.wrappedValue.signatureID = model.defaultSignatureID(account: new) }
                Spacer()
                Button(d.showCcBcc ? "Skryť Cc/Bcc" : "Cc/Bcc") { draft.wrappedValue.showCcBcc.toggle() }
                    .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
            }
            Divider().padding(.leading, 16)
            row("Komu") { AddressField(text: draft.to, focus: $focus, field: .to) }
                .zIndex(3)
            if d.showCcBcc {
                Divider().padding(.leading, 16)
                row("Kópia") { AddressField(text: draft.cc, focus: $focus, field: .cc) }.zIndex(2)
                Divider().padding(.leading, 16)
                row("Skrytá") { AddressField(text: draft.bcc, focus: $focus, field: .bcc) }.zIndex(1)
            }
            Divider().padding(.leading, 16)
            row("Predmet") {
                TextField("", text: draft.subject).textFieldStyle(.plain).font(.headline).focused($focus, equals: .subject)
            }
            Divider()
        }
    }

    func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            content()
        }
        .padding(.horizontal, 16).frame(minHeight: 36)
    }

    func signatureView(_ s: Signature) -> some View {
        Group {
            if s.isHTML {
                Text(AttributedString(htmlSnippet: s.body) ?? AttributedString(s.plain))
            } else {
                Text(s.body)
            }
        }
        .font(.body).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 5)
    }

    var quoteView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { showQuote.toggle() } } label: {
                Label(showQuote ? "Skryť pôvodnú správu" : "Zobraziť pôvodnú správu", systemImage: "ellipsis")
                    .font(.callout)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            if showQuote {
                Text(d.quoted).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        }
        .padding(.leading, 5)
    }

    var attachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(d.attachments, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        Text(url.lastPathComponent).lineLimit(1)
                        Text(fileSize(url)).foregroundStyle(.tertiary)
                        Button { draft.wrappedValue.attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.6), in: .capsule)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    var bottomBar: some View {
        HStack(spacing: 14) {
            Button { importing = true } label: { Label("Priložiť", systemImage: "paperclip") }
            Menu {
                Picker("Podpis", selection: draft.signatureID) {
                    Text("Bez podpisu").tag(String?.none)
                    ForEach(model.signatures) { s in Text(s.name).tag(Optional(s.id)) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Upraviť podpisy…") { openSettings() }
            } label: {
                Label(signature?.name ?? "Bez podpisu", systemImage: "signature")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
            } else if !note.isEmpty {
                Text(note).foregroundStyle(.secondary).transition(.opacity)
            }
            Button { Task { await saveDraft() } } label: { Label("Uložiť koncept", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    func scheduledBanner(_ at: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill").foregroundStyle(.orange)
            Text("Naplánované na \(at.formatted(date: .abbreviated, time: .shortened))")
            Spacer()
            Button("Zmeniť čas…") { scheduleDate = at; scheduling = true }.buttonStyle(.borderless)
            Button("Zrušiť plán") { draft.wrappedValue.scheduledAt = nil }.buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    var sendButton: some View {
        HStack(spacing: 0) {
            if let at = d.scheduledAt {
                Button { send(at: max(at, Date().addingTimeInterval(30))) } label: { Label("Naplánovať", systemImage: "clock").labelStyle(.titleAndIcon) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            } else {
                Button { send(at: nil) } label: { Label("Odoslať", systemImage: "paperplane.fill").labelStyle(.titleAndIcon) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
            Menu {
                if d.scheduledAt != nil { Button("Odoslať teraz") { send(at: nil) } }
                Section("Odoslať neskôr") {
                    ForEach(Self.laterOptions(), id: \.0) { opt in
                        Button("\(opt.0) – \(opt.1.formatted(date: .omitted, time: .shortened))") { send(at: opt.1) }
                    }
                    Button("Vybrať dátum a čas…") { scheduling = true }
                }
            } label: { Image(systemName: "chevron.down") }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!canSend)
                .popover(isPresented: $scheduling, arrowEdge: .bottom) { schedulePopover }
        }
        .buttonStyle(.glassProminent)
    }

    var schedulePopover: some View {
        VStack(alignment: .trailing, spacing: 12) {
            DatePicker("", selection: $scheduleDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical).labelsHidden()
            HStack {
                Text("Courier musí v tom čase bežať.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Naplánovať") { scheduling = false; send(at: scheduleDate) }.buttonStyle(.glassProminent)
            }
        }
        .padding(16).frame(width: 320)
    }

    static func laterOptions() -> [(String, Date)] {
        let cal = Calendar.current
        let now = Date()
        func at(_ day: Date, _ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: day)! }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        var out: [(String, Date)] = []
        if at(now, 18) > now.addingTimeInterval(1800) { out.append(("Dnes večer", at(now, 18))) }
        out.append(("Zajtra ráno", at(tomorrow, 8)))
        out.append(("Zajtra popoludní", at(tomorrow, 13)))
        let monday = cal.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        out.append(("V pondelok ráno", at(monday, 8)))
        return out
    }

    // MARK: Actions

    func addFiles(_ urls: [URL]) {
        for u in urls {
            // Copy now: a security-scoped URL may stop being readable later.
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("CourierCompose/\(UUID().uuidString)").appendingPathComponent(u.lastPathComponent)
            let scoped = u.startAccessingSecurityScopedResource()
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: u, to: dst)
            if scoped { u.stopAccessingSecurityScopedResource() }
            if FileManager.default.fileExists(atPath: dst.path) { draft.wrappedValue.attachments.append(dst) }
        }
    }

    func fileSize(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    func send(at date: Date?) {
        error = nil
        do {
            try model.queue(id, at: date)
            dismissWindow()
        } catch { self.error = error.localizedDescription }
    }

    func saveDraft() async {
        note = "Ukladám…"
        do {
            try await model.saveDraft(id)
            note = "Koncept uložený"
            try? await Task.sleep(for: .seconds(2.5))
            if note == "Koncept uložený" { withAnimation { note = "" } }
        } catch { note = ""; self.error = error.localizedDescription }
    }
}

extension AttributedString {
    /// Small HTML (a signature) rendered for display.
    init?(htmlSnippet html: String) {
        guard let data = "<div style=\"font-family:-apple-system;font-size:13px\">\(html)</div>".data(using: .utf8),
              let ns = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                       .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { return nil }
        self.init(ns)
    }
}

/// Recipient field with suggestions from Apple Contacts and mail history. ↑↓ choose, ↩ or ⇥ accepts.
struct AddressField: View {
    @EnvironmentObject var model: AppModel
    @Binding var text: String
    var focus: FocusState<ComposeView.Field?>.Binding
    let field: ComposeView.Field
    @State private var highlighted = 0
    @State private var dismissed = false

    var fragment: String {
        guard let last = text.split(separator: ",", omittingEmptySubsequences: false).last else { return "" }
        return last.trimmingCharacters(in: .whitespaces)
    }
    var suggestions: [ContactBook.Entry] {
        guard focus.wrappedValue == field, !dismissed, !fragment.isEmpty, !fragment.contains("<") else { return [] }
        let already = Set(MIME.parseAddresses(text).map { $0.address.lowercased() })
        return model.contacts.suggest(fragment, excluding: already)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .focused(focus, equals: field)
            .onChange(of: text) { highlighted = 0; dismissed = false }
            .onKeyPress(.downArrow) { guard !suggestions.isEmpty else { return .ignored }; highlighted = min(highlighted + 1, suggestions.count - 1); return .handled }
            .onKeyPress(.upArrow) { guard !suggestions.isEmpty else { return .ignored }; highlighted = max(highlighted - 1, 0); return .handled }
            .onKeyPress(.return) { accept() ? .handled : .ignored }
            .onKeyPress(.tab) { accept() ? .handled : .ignored }
            .onKeyPress(.escape) { guard !suggestions.isEmpty else { return .ignored }; dismissed = true; return .handled }
            .overlay(alignment: .topLeading) {
                let list = suggestions
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element) { i, e in
                            HStack(spacing: 8) {
                                Avatar(name: e.name, address: e.address, size: 22)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.name.isEmpty ? e.address : e.name).font(.callout)
                                    if !e.name.isEmpty { Text(e.address).font(.caption).foregroundStyle(i == highlighted ? .white.opacity(0.8) : .secondary) }
                                }
                                Spacer()
                            }
                            .foregroundStyle(i == highlighted ? .white : .primary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(i == highlighted ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { highlighted = i; _ = accept() }
                        }
                    }
                    .padding(5)
                    .frame(width: 340)
                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .offset(y: 26)
                }
            }
    }

    func accept() -> Bool {
        let list = suggestions
        guard highlighted < list.count else { return false }
        let e = list[highlighted]
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        let picked = EmailAddress(name: e.name, address: e.address).full
        text = (parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } + [picked]).joined(separator: ", ") + ", "
        highlighted = 0
        return true
    }
}
