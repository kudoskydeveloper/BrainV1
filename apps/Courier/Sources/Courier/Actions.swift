import AppKit
import CourierCore
import SwiftUI

extension AppModel {
    /// Messages a delete / archive / move acts on: the conversation's messages in the folder being viewed,
    /// or, in combined views, its messages outside Sent, Drafts, Trash and Spam (your sent copies stay).
    func actionTargets(_ m: MessageSummary) -> [MessageSummary] {
        let thread = store.thread(account: m.accountID, id: m.threadID)
        if case .folder(_, let path) = selection {
            let inFolder = thread.filter { $0.folder == path }
            return inFolder.isEmpty ? [m] : inFolder
        }
        let skip = Set((folders[m.accountID] ?? []).filter { [.sent, .drafts, .trash, .junk].contains($0.role) }.map(\.path))
        let list = thread.filter { !skip.contains($0.folder) }
        return list.isEmpty ? [m] : list
    }

    func roleFolder(_ role: FolderRole, account: String) -> Folder? { folders[account]?.first { $0.role == role } }

    var viewingTrash: Bool {
        if case .folder(let a, let p) = selection { return folder(a, p)?.role == .trash }
        return false
    }

    /// Delete = move to Trash (recoverable); in Trash it is permanent, after a confirmation.
    func delete(_ m: MessageSummary) {
        let targets = actionTargets(m)
        if viewingTrash || roleFolder(.trash, account: m.accountID) == nil {
            let alert = NSAlert()
            alert.messageText = targets.count > 1 ? "Natrvalo vymazať \(targets.count) správy?" : "Natrvalo vymazať správu?"
            alert.informativeText = "Z koša na serveri sa už nedá obnoviť."
            alert.addButton(withTitle: "Vymazať")
            alert.addButton(withTitle: "Zrušiť")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            perform(targets, to: nil)
        } else {
            perform(targets, to: roleFolder(.trash, account: m.accountID)?.path)
        }
    }

    func archive(_ m: MessageSummary) {
        guard let arch = roleFolder(.archive, account: m.accountID) ?? roleFolder(.all, account: m.accountID) else {
            accountErrors[m.accountID] = "Účet nemá priečinok Archív."
            return
        }
        perform(actionTargets(m), to: arch.path)
    }

    func move(_ m: MessageSummary, to path: String) { perform(actionTargets(m), to: path) }

    var viewingJunk: Bool {
        if case .folder(let a, let p) = selection { return folder(a, p)?.role == .junk }
        return false
    }

    func isJunk(_ m: MessageSummary) -> Bool { folder(m.accountID, m.folder)?.role == .junk }

    /// Spam → the account's Junk folder (the server's spam filter learns from it); "not spam" → back to the inbox.
    func markSpam(_ m: MessageSummary, _ spam: Bool) {
        let role: FolderRole = spam ? .junk : .inbox
        guard let target = roleFolder(role, account: m.accountID) else {
            accountErrors[m.accountID] = spam ? "Účet nemá priečinok Spam." : "Účet nemá Doručenú poštu."
            return
        }
        let list = spam ? actionTargets(m) : (isJunk(m) ? store.thread(account: m.accountID, id: m.threadID).filter(isJunk) : [m])
        perform(list.isEmpty ? [m] : list, to: target.path)
    }

    // MARK: Several selected

    /// The selected conversations (rows), in list order.
    var selectedRows: [MessageSummary] { messages.filter { selectedIDs.contains($0.id) } }

    /// Everything the selected rows stand for (whole conversations, as for a single delete), each message once.
    private var selectedTargets: [MessageSummary] {
        var seen = Set<Int64>()
        return selectedRows.flatMap(actionTargets).filter { seen.insert($0.id).inserted }
    }

    func deleteSelected() {
        let targets = selectedTargets
        guard !targets.isEmpty else { return }
        let permanent = viewingTrash || Set(targets.map(\.accountID)).contains { roleFolder(.trash, account: $0) == nil }
        if permanent {
            let alert = NSAlert()
            alert.messageText = "Natrvalo vymazať \(selectedRows.count) konverzácií?"
            alert.informativeText = "Z koša na serveri sa už nedajú obnoviť."
            alert.addButton(withTitle: "Vymazať")
            alert.addButton(withTitle: "Zrušiť")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        performEach(targets) { permanent ? nil : self.roleFolder(.trash, account: $0)?.path }
    }

    func archiveSelected() {
        performEach(selectedTargets) { (self.roleFolder(.archive, account: $0) ?? self.roleFolder(.all, account: $0))?.path ?? "" }
    }

    func spamSelected(_ spam: Bool) {
        performEach(selectedTargets) { self.roleFolder(spam ? .junk : .inbox, account: $0)?.path ?? "" }
    }

    func moveSelected(toRole role: FolderRole) {
        performEach(selectedTargets) { self.roleFolder(role, account: $0)?.path ?? "" }
    }

    /// Read / unread for all selected conversations (every message in them).
    func markSelected(read: Bool) {
        let list = selectedRows.flatMap { store.thread(account: $0.accountID, id: $0.threadID) }.filter { $0.seen != read }
        guard !list.isEmpty else { return }
        Task {
            try? await sync.setSeen(list, read)
            folders = Dictionary(grouping: store.folders(), by: \.accountID)
            loadMessages()
        }
    }

    var selectionHasUnread: Bool { selectedRows.contains(where: isUnread) }

    /// Like perform, across accounts: each account's messages go to that account's folder ("" = it has none: left alone,
    /// nil = delete for good). The rows leave the list at once; the selection is cleared.
    private func performEach(_ targets: [MessageSummary], to path: @escaping (String) -> String?) {
        guard !targets.isEmpty else { return }
        let groups = Dictionary(grouping: targets, by: \.accountID).compactMap { a, list -> (String, [MessageSummary], String?)? in
            let p = path(a)
            if p == "" { accountErrors[a] = "Účet \(account(a)?.email ?? "") nemá taký priečinok."; return nil }
            return (a, list, p)
        }
        let ids = Set(groups.flatMap { $0.1.map(\.id) }), keys = Set(groups.flatMap { $0.1.map(\.threadKey) })
        selectedIDs = []
        withAnimation(.smooth(duration: 0.25)) { messages.removeAll { ids.contains($0.id) || keys.contains($0.threadKey) } }
        Task {
            for (a, list, p) in groups {
                do { try await sync.move(list, to: p) } catch { accountErrors[a] = error.localizedDescription }
            }
            folders = Dictionary(grouping: store.folders(), by: \.accountID)
            loadMessages()
        }
    }

    /// Removes the rows right away (and selects the next conversation), then does the server work.
    private func perform(_ targets: [MessageSummary], to path: String?) {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let keys = Set(targets.map(\.threadKey))
        if let current = selectedMessageID, let i = messages.firstIndex(where: { $0.id == current }), keys.contains(messages[i].threadKey) {
            let next = messages.indices.contains(i + 1) ? messages[i + 1] : (i > 0 ? messages[i - 1] : nil)
            selectedMessageID = next?.id
        }
        withAnimation(.smooth(duration: 0.25)) { messages.removeAll { ids.contains($0.id) || keys.contains($0.threadKey) } }
        Task {
            do { try await sync.move(targets, to: path) } catch { accountErrors[targets[0].accountID] = error.localizedDescription }
            folders = Dictionary(grouping: store.folders(), by: \.accountID)
            loadMessages()
        }
    }

    /// Opens a message from Drafts in the composer; saving or sending replaces it on the server.
    /// Downloads the draft's body if needed, then opens it.
    func openDraft(_ m: MessageSummary, _ open: @escaping (UUID) -> Void) {
        Task {
            if bodies[m.id] == nil, store.body(id: m.id) == nil {
                do { bodies[m.id] = try await sync.fetchBody(m) } catch { bodyErrors[m.id] = error.localizedDescription; return }
            }
            guard let id = editDraft(m) else { return }
            // the draft's attachments come along: downloaded into a folder of their own, so editing and sending keeps them
            let list = (bodies[m.id] ?? store.body(id: m.id))?.attachments ?? store.attachments(id: m.id)
            if !list.isEmpty {
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Courier/DraftFiles/\(m.id)")
                try? FileManager.default.removeItem(at: dir)
                var urls: [URL] = []
                for (i, a) in list.enumerated() {
                    do { urls.append(try await sync.saveAttachment(m, index: i, filename: a.filename, to: dir)) }
                    catch { bodyErrors[m.id] = "Prílohu \(a.filename) sa nepodarilo stiahnuť: \(error.localizedDescription)" }
                }
                drafts[id]?.attachments = urls
            }
            open(id)
        }
    }

    func editDraft(_ m: MessageSummary) -> UUID? {
        guard let a = account(m.accountID) else { return nil }
        var d = ComposeDraft(accountID: a.id, signatureID: nil)
        d.to = m.to
        d.subject = m.subject
        let body = bodies[m.id] ?? store.body(id: m.id)
        d.body = body?.text ?? body?.html.map(MIME.stripHTML) ?? ""
        d.cc = body?.cc ?? ""
        d.showCcBcc = !d.cc.isEmpty
        let h = store.threadHeaders(id: m.id)
        if !h.messageID.isEmpty { d.messageID = h.messageID }
        if let r = h.references.last { d.inReplyTo = r; d.references = h.references }
        drafts[d.id] = d
        return d.id
    }

    func isDraft(_ m: MessageSummary) -> Bool { folder(m.accountID, m.folder)?.role == .drafts }
}

/// Archive / delete / move items shared by the toolbar and context menus.
struct MessageActionsMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    let m: MessageSummary

    var body: some View {
        if model.isDraft(m) {
            Button("Upraviť koncept") { model.openDraft(m) { openWindow(id: "compose", value: $0) } }
        }
        Button("Archivovať") { model.archive(m) }
        if model.isJunk(m) {
            Button("Nie je spam") { model.markSpam(m, false) }
        } else {
            Button("Spam") { model.markSpam(m, true) }
        }
        Button(model.viewingTrash ? "Vymazať natrvalo" : "Vymazať") { model.delete(m) }
        Menu("Presunúť do") {
            ForEach((model.folders[m.accountID] ?? []).filter { $0.selectable && $0.path != m.folder }) { f in
                Button(f.displayName) { model.move(m, to: f.path) }
            }
        }
    }
}

/// The same actions for several selected conversations (context menu and the panel on the right).
struct BulkActionsMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button(model.selectionHasUnread ? "Označiť ako prečítané" : "Označiť ako neprečítané") { model.markSelected(read: model.selectionHasUnread) }
        Button("Archivovať") { model.archiveSelected() }
        Button(model.viewingJunk ? "Nie je spam" : "Spam") { model.spamSelected(!model.viewingJunk) }
        Button(model.viewingTrash ? "Vymazať natrvalo" : "Vymazať") { model.deleteSelected() }
        Menu("Presunúť do") {
            ForEach([FolderRole.inbox, .archive, .junk, .trash], id: \.self) { r in Button(r.title) { model.moveSelected(toRole: r) } }
        }
    }
}

/// Shown on the right when several conversations are selected: what's selected and what can be done with them, like Mail.
struct BulkPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let rows = model.selectedRows
        VStack(spacing: 18) {
            ZStack {
                ForEach(Array(rows.prefix(3).enumerated().reversed()), id: \.offset) { i, _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.background.secondary)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
                        .frame(width: 150, height: 110)
                        .rotationEffect(.degrees(Double(i) * -4))
                        .offset(y: CGFloat(i) * -4)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                Image(systemName: "envelope.fill").font(.system(size: 34)).foregroundStyle(.tint)
            }
            .frame(height: 130)
            Text("\(rows.count) vybraných konverzácií").font(.title2.weight(.semibold))
            Text(rows.prefix(4).map(\.fromDisplay).joined(separator: ", ") + (rows.count > 4 ? " a ďalší" : ""))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button { model.markSelected(read: model.selectionHasUnread) } label: {
                    Label(model.selectionHasUnread ? "Prečítané" : "Neprečítané", systemImage: model.selectionHasUnread ? "envelope.open" : "envelope.badge")
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Button { model.archiveSelected() } label: { Label("Archivovať", systemImage: "archivebox") }
                    .keyboardShortcut("a", modifiers: [.command, .control])
                Button(role: .destructive) { model.deleteSelected() } label: { Label("Vymazať", systemImage: "trash") }
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            Text("⇧⌘U prečítané · ⌃⌘A archivovať · ⌫ vymazať").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}
