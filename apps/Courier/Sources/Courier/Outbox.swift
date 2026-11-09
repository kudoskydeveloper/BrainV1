import AppKit
import CourierCore
import Quartz
import SwiftUI

struct PendingUndo: Equatable {
    var itemID: String
    var draft: ComposeDraft
    var deadline: Date
    var scheduledFor: Date?    // set for "send later": the bar then says when
}

struct AttachmentPreview: Identifiable {
    let id = UUID()
    var url: URL
    var message: MessageSummary
    var index: Int
}

extension AppModel {
    static let undoSeconds: TimeInterval = 10

    // MARK: Sending through the outbox

    /// Queues the draft. Without a date it goes out after the undo window; with a date it is scheduled.
    func queue(_ id: UUID, at date: Date? = nil, quiet: Bool = false) throws {
        guard var d = drafts[id] else { return }
        let m = d.outgoing(signature: signatures.first { $0.id == d.signatureID })
        guard !m.recipients.isEmpty else { throw MailError.notFound("Chýba príjemca.") }
        let when = date ?? Date().addingTimeInterval(Self.undoSeconds)
        let item = try store.enqueue(m, at: when)
        d.sent = true
        drafts[id] = d
        outbox = store.outbox()
        if !quiet { undo = PendingUndo(itemID: item.id, draft: d, deadline: Date().addingTimeInterval(Self.undoSeconds), scheduledFor: date) }
    }

    /// Takes the message back out of the outbox and returns a draft to reopen in a composer.
    func undoSend() -> UUID? {
        guard let u = undo else { return nil }
        undo = nil
        guard store.dequeue(u.itemID, keepFiles: true) != nil else { return nil }
        outbox = store.outbox()
        var d = u.draft
        d.sent = false
        let copy = ComposeDraft(copying: d)
        drafts[copy.id] = copy
        return copy.id
    }

    /// Reopens a queued (scheduled or failed) message in the composer and removes it from the outbox.
    func edit(_ item: OutboxItem) -> UUID? {
        guard store.dequeue(item.id, keepFiles: true) != nil else { return nil }
        outbox = store.outbox()
        var d = ComposeDraft(from: item.message)
        if item.error == nil { d.scheduledAt = item.sendAt }
        drafts[d.id] = d
        return d.id
    }

    func sendNow(_ item: OutboxItem) {
        store.reschedule(item.id, at: Date())
        outbox = store.outbox()
    }

    func cancel(_ item: OutboxItem) {
        store.dequeue(item.id)
        outbox = store.outbox()
    }

    func tickOutbox() async {
        if let u = undo, u.deadline < Date() { undo = nil }
        guard store.outbox().contains(where: { $0.sendAt <= Date() && $0.error == nil }) else { return }
        let sent = await sync.flushOutbox()
        outbox = store.outbox()
        if !sent.isEmpty { reload() }
        if let failed = outbox.first(where: { $0.error != nil }), selection != .outbox {
            accountErrors[failed.message.accountID] = "Správa „\(failed.message.subject)“ sa neodoslala: \(failed.error ?? "")"
        }
    }

    // MARK: Signatures

    func defaultSignatureID(account: String) -> String? { store.defaultSignature(account: account) }

    func save(_ s: Signature) {
        try? store.save(s)
        signatures = store.signatures()
    }

    func deleteSignature(_ s: Signature) {
        try? store.deleteSignature(s.id)
        signatures = store.signatures()
    }

    func setDefaultSignature(account: String, _ id: String?) {
        try? store.setDefaultSignature(account: account, id)
        objectWillChange.send()
    }

    // MARK: Attachments

    var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first! }

    func previewAttachment(_ m: MessageSummary, index: Int, name: String) {
        Task {
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Courier/\(m.id)-\(index)")
                try? FileManager.default.removeItem(at: dir)
                let url = try await sync.saveAttachment(m, index: index, filename: name, to: dir)
                preview = AttachmentPreview(url: url, message: m, index: index)
            } catch { bodyErrors[m.id] = error.localizedDescription }
        }
    }

    func saveAttachment(_ m: MessageSummary, index: Int, name: String, to dir: URL? = nil, reveal: Bool = true) {
        Task {
            do {
                let url = try await sync.saveAttachment(m, index: index, filename: name, to: dir ?? downloads)
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch { bodyErrors[m.id] = error.localizedDescription }
        }
    }

    func saveAllAttachments(_ m: MessageSummary) {
        Task {
            var urls: [URL] = []
            for (i, a) in store.attachments(id: m.id).enumerated() {
                if let u = try? await sync.saveAttachment(m, index: i, filename: a.filename, to: downloads) { urls.append(u) }
            }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    func saveAttachmentAs(_ m: MessageSummary, index: Int, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloads
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            do {
                let (_, data) = try await sync.attachmentData(m, index: index, filename: name)
                try data.write(to: target)
            } catch { bodyErrors[m.id] = error.localizedDescription }
        }
    }

    func openAttachment(_ m: MessageSummary, index: Int, name: String) {
        Task {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Courier/\(m.id)-\(index)")
            try? FileManager.default.removeItem(at: dir)
            if let url = try? await sync.saveAttachment(m, index: index, filename: name, to: dir) { NSWorkspace.shared.open(url) }
        }
    }

    func show(_ m: MessageSummary) {
        selection = .folder(account: m.accountID, path: m.folder)
        selectedMessageID = m.id
    }
}

// MARK: Views

/// "Odosiela sa… Zrušiť" bar, Apple Mail style, at the bottom of the main window.
struct UndoBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    let undo: PendingUndo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(undo.deadline.timeIntervalSince(ctx.date).rounded(.up)))
            HStack(spacing: 14) {
                Image(systemName: undo.scheduledFor == nil ? "paperplane.fill" : "clock.fill").foregroundStyle(.tint)
                Text(undo.scheduledFor.map { "Naplánované na \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Odosiela sa o \(left) s")
                    .monospacedDigit()
                Button("Zrušiť odoslanie") {
                    if let id = model.undoSend() { openWindow(id: "compose", value: id) }
                }
                .buttonStyle(.borderless).fontWeight(.semibold)
                .keyboardShortcut("z")
            }
            .font(.callout)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

/// Queued and scheduled messages.
struct OutboxView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        List {
            ForEach(model.outbox) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.error != nil ? "exclamationmark.triangle.fill" : "clock")
                        .foregroundStyle(item.error != nil ? .orange : .secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.message.subject.isEmpty ? "(bez predmetu)" : item.message.subject).font(.headline).lineLimit(1)
                        Text("Komu: " + item.message.to.map(\.display).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if let e = item.error { Text(e).font(.caption).foregroundStyle(.orange) }
                        else { Text(item.sendAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let id = model.edit(item) { openWindow(id: "compose", value: id) } }
                .contextMenu {
                    Button("Odoslať teraz") { model.sendNow(item) }
                    Button("Upraviť…") { if let id = model.edit(item) { openWindow(id: "compose", value: id) } }
                    Divider()
                    Button("Zrušiť a zahodiť", role: .destructive) { model.cancel(item) }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.outbox.isEmpty {
                ContentUnavailableView("Nič na odoslanie", systemImage: "clock", description: Text("Naplánované správy sa zobrazia tu. Courier ich odošle, keď beží."))
            }
        }
        .navigationTitle("Na odoslanie")
    }
}

/// All attachments across mailboxes; search filters by file name, sender or subject.
struct AttachmentsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Set<String> = []

    var body: some View {
        List(selection: $selected) {
            ForEach(model.attachmentHits) { h in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (h.attachment.filename as NSString).pathExtension) ?? .data))
                        .resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.attachment.filename).font(.headline.weight(.medium)).lineLimit(1)
                        Text("\(h.message.fromDisplay) · \(h.message.subject)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(h.message.date.listLabel).font(.caption).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(h.attachment.size), countStyle: .file)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
                .tag(h.id)
                .contextMenu { AttachmentMenu(m: h.message, index: h.index, name: h.attachment.filename, showMessage: true) }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
            if let h = model.attachmentHits.first(where: { ids.contains($0.id) }) {
                model.previewAttachment(h.message, index: h.index, name: h.attachment.filename)
            }
        }
        .overlay {
            if model.attachmentHits.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "Žiadne prílohy" : "Nič sa nenašlo", systemImage: "paperclip",
                                       description: Text("Hľadaj podľa názvu súboru, odosielateľa alebo predmetu."))
            }
        }
        .navigationTitle("Prílohy")
        .navigationSubtitle("\(model.attachmentHits.count)")
        .onAppear { model.loadMessages() }
    }
}

struct AttachmentMenu: View {
    @EnvironmentObject var model: AppModel
    let m: MessageSummary
    let index: Int
    let name: String
    var showMessage = false
    var body: some View {
        Button("Rýchly náhľad") { model.previewAttachment(m, index: index, name: name) }
        Button("Otvoriť") { model.openAttachment(m, index: index, name: name) }
        Divider()
        Button("Uložiť do Stiahnutých") { model.saveAttachment(m, index: index, name: name) }
        Button("Uložiť ako…") { model.saveAttachmentAs(m, index: index, name: name) }
        if showMessage { Divider(); Button("Zobraziť správu") { model.show(m) } }
    }
}

/// Quick Look in a sheet.
struct PreviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let p: AttachmentPreview

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(p.url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Otvoriť") { NSWorkspace.shared.open(p.url) }
                Button("Uložiť do Stiahnutých") { model.saveAttachment(p.message, index: p.index, name: p.url.lastPathComponent); dismiss() }
                Button("Hotovo") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glassProminent)
            }
            .padding(12)
            QuickLookView(url: p.url)
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) { v.previewItem = url as NSURL }
}
