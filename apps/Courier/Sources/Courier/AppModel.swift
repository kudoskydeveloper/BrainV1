import CourierCore
import SwiftUI

enum SidebarItem: Hashable {
    case board
    case unified
    /// One folder kind across all accounts (all drafts, all sent, …)
    case role(FolderRole)
    case project(String)
    case folder(account: String, path: String)
    case status(TicketStatus)
    case tag(String)
    case outbox
    case attachments
    case contacts
}

@MainActor
final class AppModel: ObservableObject {
    let store: Store
    let sync: MailSync

    @Published var accounts: [Account] = []
    @Published var folders: [String: [Folder]] = [:] { didSet { refreshProjectUnread() } }
    @Published var projects: [Project] = [] { didSet { refreshProjectUnread() } }
    /// Unread per project, counted in the background (the sidebar redraws on every click and used to query each time).
    @Published var projectUnread: [String: Int] = [:]
    private var projectUnreadPending = false
    @Published var tags: [Tag] = []
    @Published var tickets: [String: Ticket] = [:]
    @Published var selection: SidebarItem? = .board { didSet { if oldValue != selection { selectionChanged() } } }
    /// One row per conversation: its newest message.
    @Published var messages: [MessageSummary] = []
    @Published var threadStats: [String: (count: Int, unread: Int)] = [:]
    @Published var selectedMessageID: Int64? {
        didSet {
            guard oldValue != selectedMessageID else { return }
            // one message picked from code (next after delete, a notification…): the list selection follows
            let want: Set<Int64> = selectedMessageID.map { [$0] } ?? []
            if selectedMessageID != nil || selectedIDs.count <= 1, selectedIDs != want { selectedIDs = want }
            openSelected()
        }
    }
    /// The list's selection (⌘- or ⇧-click for several). One → it opens on the right; more → bulk actions there.
    @Published var selectedIDs: Set<Int64> = [] {
        didSet {
            guard oldValue != selectedIDs else { return }
            let single = selectedIDs.count == 1 ? selectedIDs.first : nil
            if selectedMessageID != single { selectedMessageID = single }
        }
    }
    /// The open conversation, oldest first, with bodies loaded on demand.
    @Published var conversation: [MessageSummary] = []
    @Published var bodies: [Int64: MessageBody] = [:]
    @Published var bodyErrors: [Int64: String] = [:]
    @Published var expanded: Set<Int64> = []
    @Published var syncing = false
    @Published var backfillStatus = ""
    @Published var accountErrors: [String: String] = [:]
    @Published var search = "" { didSet { loadMessages() } }
    @Published var unreadOnly = false { didSet { loadMessages() } }
    /// The conversation open on the right (its thread key): kept in the Unread list until another one opens.
    var openThread: String?
    /// nil = overview (people + one row per other group); otherwise only that group.
    @Published var category: MailCategory? { didSet { if oldValue != category { selectedMessageID = nil; loadMessages() } } }
    @Published var bundles: [CategoryBundle] = []
    @Published var categoryCounts: [MailCategory: (total: Int, unread: Int)] = [:]
    /// Conversation heads of the current view before the group filter.
    private(set) var allHeads: [MessageSummary] = []
    @Published var showAddAccount = false
    @Published var editingProject: Project?
    @Published var drafts: [UUID: ComposeDraft] = [:]
    @Published var outbox: [OutboxItem] = []
    @Published var signatures: [Signature] = []
    /// The send that can still be undone (shown as a bar at the bottom of the main window).
    @Published var undo: PendingUndo?
    /// Address book: everyone from the mail, loaded when the tab opens.
    @Published var mailContacts: [MailContact] = []
    @Published var contactsLoading = false
    @Published var selectedContact: String?
    /// The Adresár tab in the sidebar can be turned off (View menu, Settings, or its context menu).
    @Published var showContactsTab = UserDefaults.standard.object(forKey: "sidebar.contacts") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showContactsTab, forKey: "sidebar.contacts")
            if !showContactsTab, selection == .contacts { selection = .unified }
        }
    }
    /// "Skopírované" toast after clicking an address.
    @Published var copiedText: String?
    @Published var preview: AttachmentPreview?
    @Published var attachmentHits: [Store.AttachmentHit] = []
    let contacts = ContactBook()
    private var outboxTimer: Timer?
    /// Accounts whose folder list is open in the sidebar (remembered between launches).
    @Published var expandedAccounts: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "expandedAccounts") ?? []) {
        didSet { UserDefaults.standard.set(Array(expandedAccounts), forKey: "expandedAccounts") }
    }

    private var timer: Timer?
    private var ticks = 0
    private var backfilling = false
    private var lastBackfillReload = Date.distantPast

    init() {
        do { store = try Store() } catch { fatalError("Courier: \(error.localizedDescription)") }
        sync = MailSync(store: store)
        reload()
        if accounts.isEmpty { showAddAccount = true }
        Task { await refreshAll() }
        // Inboxes every minute (new mail, notifications), everything else every ten minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ticks += 1
                if self.ticks % 10 == 0 { await self.refreshAll() } else { await self.checkInboxes() }
            }
        }
        Notifier.shared.start(model: self)
        outboxTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickOutbox() }
        }
        contacts.load(store: store, myAddresses: Set(accounts.map { $0.email.lowercased() }))
    }

    // MARK: Data

    func reload() {
        accounts = store.accounts()
        folders = Dictionary(grouping: store.folders(), by: \.accountID)
        projects = store.projects()
        tags = store.tags()
        tickets = store.tickets()
        outbox = store.outbox()
        signatures = store.signatures()
        loadMessages()
        Notifier.shared.updateBadge(store)
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
    func folder(_ account: String, _ path: String) -> Folder? { folders[account]?.first { $0.path == path } }
    var selectedMessage: MessageSummary? { messages.first { $0.id == selectedMessageID } ?? selectedMessageID.flatMap(store.message) }
    func ticket(_ m: MessageSummary) -> Ticket? { tickets[m.threadKey] }
    func tag(_ name: String) -> Tag? { tags.first { $0.name == name } }

    /// Bumped on every load; an older query that finishes late is dropped.
    private var loadGeneration = 0
    /// The view the shown rows belong to: a new view swaps the list at once, the same one animates rows coming and going.
    private var loadedView: String = ""

    /// Queries run off the main thread so clicking in the sidebar highlights at once; the rows follow a moment later.
    func loadMessages() {
        loadGeneration += 1
        let gen = loadGeneration
        let q = search.trimmingCharacters(in: .whitespaces)
        let sel = selection
        let project = { if case .project(let id) = sel { return self.projects.first { $0.id == id } }; return nil }()
        let store = store
        Task.detached(priority: .userInitiated) {
            var list: [MessageSummary]
            if !q.isEmpty, sel != .contacts {   // the address book filters its own list
                var acc: String? = nil
                if case .folder(let a, _) = sel { acc = a }
                list = store.search(q, account: acc, limit: 600)
            } else {
                switch sel {
                case .unified, .board, nil: list = store.unifiedInbox(limit: 1500)
                case .role(let r): list = store.unified(role: r, limit: 1500)
                case .project: list = project.map { store.messages(project: $0, limit: 1500) } ?? []
                case .folder(let a, let p): list = store.messages(account: a, folder: p, limit: 1500)
                case .status(let s): list = store.messages(status: s)
                case .tag(let t): list = store.messages(tag: t)
                case .outbox, .attachments, .contacts: list = []
                }
            }
            var seen = Set<String>()
            let heads = list.filter { seen.insert($0.threadKey).inserted }
            let stats = store.threadStats(Set(heads.map(\.threadKey)))
            let hits = sel == .attachments ? store.attachmentHits(q) : nil
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                self.applyLoaded(heads, stats: stats, hits: hits, view: "\(String(describing: sel))|\(q)")
            }
        }
    }

    private func applyLoaded(_ heads: [MessageSummary], stats: [String: (count: Int, unread: Int)], hits: [Store.AttachmentHit]?, view: String) {
        threadStats = stats
        if let hits { attachmentHits = hits }
        // the open conversation stays in the Unread list after it's been read, until another one is opened
        var visible = unreadOnly ? heads.filter { !$0.seen || (threadStats[$0.threadKey]?.unread ?? 0) > 0 || $0.threadKey == openThread } : heads
        // Groups: in inbox-like views everything that is not from a person is bundled into one row per group.
        var counts: [MailCategory: (total: Int, unread: Int)] = [:]
        bundles = []
        allHeads = visible
        if groupsApply {
            for m in visible { let c = counts[m.category] ?? (0, 0); counts[m.category] = (c.total + 1, c.unread + (isUnread(m) ? 1 : 0)) }
            if let category {
                visible = visible.filter { $0.category == category }
            } else {
                for c in MailCategory.allCases where c != .people {
                    let list = visible.filter { $0.category == c }
                    guard let newest = list.first else { continue }
                    var names: [String] = []
                    for m in list where !names.contains(m.fromDisplay) && names.count < 4 { names.append(m.fromDisplay) }
                    bundles.append(CategoryBundle(category: c, date: newest.date, count: list.count, unread: list.filter(isUnread).count, senders: names))
                }
                visible = visible.filter { $0.category == .people }
            }
        }
        // Animate only when rows come or go in the same view; another view or a refresh that just changes flags redraws in place.
        let sameView = view + "|\(String(describing: category))|\(unreadOnly)" == loadedView
        loadedView = view + "|\(String(describing: category))|\(unreadOnly)"
        if !sameView || visible.map(\.id) == messages.map(\.id) {
            categoryCounts = counts
            if visible != messages { messages = visible }
        } else {
            withAnimation(.smooth(duration: 0.25)) {
                categoryCounts = counts
                messages = visible
            }
        }
        Notifier.shared.updateBadge(store)   // reading, archiving or marking read changes the count
    }

    /// Groups make sense where mail arrives (inboxes, projects), not in Sent, Drafts, search or ticket views.
    var groupsApply: Bool {
        guard search.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch selection {
        case .unified, .board, .project, nil: return true
        case .folder(let a, let p): return folder(a, p)?.role == .inbox || folder(a, p)?.role == .other
        default: return false
        }
    }

    func setSenderCategory(_ m: MessageSummary, _ c: MailCategory?) {
        try? store.setSenderCategory(m.fromAddress, c)
        loadMessages()
    }

    /// Everything unread in a group (in the current view) becomes read.
    func markRead(_ c: MailCategory) {
        let list = allHeads.filter { $0.category == c }.flatMap { store.thread(account: $0.accountID, id: $0.threadID).filter { !$0.seen } }
        guard !list.isEmpty else { return }
        Task {
            try? await sync.setSeen(list, true)
            folders = Dictionary(grouping: store.folders(), by: \.accountID)
            loadMessages()
        }
    }

    func isUnread(_ m: MessageSummary) -> Bool { !m.seen || (threadStats[m.threadKey]?.unread ?? 0) > 0 }

    func unread(project: Project) -> Int { projectUnread[project.id] ?? 0 }

    /// Coalesces bursts (sync updates folders many times) into one background count.
    func refreshProjectUnread() {
        guard !projectUnreadPending else { return }
        projectUnreadPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            projectUnreadPending = false
            let list = projects, store = store
            let counts = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: list.map { ($0.id, store.unreadCount(project: $0)) })
            }.value
            if counts != projectUnread { projectUnread = counts }
        }
    }
    var unifiedUnread: Int {
        folders.values.flatMap { $0 }.filter { $0.role == .inbox }.reduce(0) { $0 + $1.unread }
    }
    // MARK: Unified folders

    /// Folder kinds that can show across all accounts in the sidebar, in this order.
    static let unifiedRoles: [FolderRole] = [.drafts, .sent, .archive, .flagged, .junk, .trash]
    static func unifiedTitle(_ r: FolderRole) -> String {
        switch r {
        case .drafts: "Všetky koncepty"; case .sent: "Všetky odoslané"; case .archive: "Všetky archívy"
        case .flagged: "Všetky označené"; case .junk: "Všetok spam"; case .trash: "Všetky koše"; default: r.title
        }
    }
    /// Shown in the sidebar? Drafts and Sent by default, the rest when turned on in Settings → Priečinky.
    static func unifiedShown(_ r: FolderRole) -> Bool {
        UserDefaults.standard.object(forKey: "unified.\(r.rawValue)") as? Bool ?? [.drafts, .sent].contains(r)
    }
    func setUnified(_ r: FolderRole, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "unified.\(r.rawValue)")
        if !on, selection == .role(r) { selection = .unified }
        objectWillChange.send()
    }
    /// Roles some account actually has a folder for.
    var availableRoles: Set<FolderRole> { Set(folders.values.flatMap { $0 }.map(\.role)) }
    func unifiedCount(_ r: FolderRole) -> Int {
        r == .drafts ? folders.values.flatMap { $0 }.filter { $0.role == .drafts }.reduce(0) { $0 + $1.total } : 0
    }

    func count(_ s: TicketStatus) -> Int { tickets.values.filter { $0.status == s }.count }

    func title(for item: SidebarItem?) -> String {
        switch item {
        case .board: "Nástenka"
        case .unified, nil: "Všetky doručené"
        case .role(let r): AppModel.unifiedTitle(r)
        case .project(let id): projects.first { $0.id == id }?.name ?? "Projekt"
        case .folder(let a, let p): folder(a, p)?.displayName ?? p
        case .status(let s): s.title
        case .tag(let t): t
        case .outbox: "Na odoslanie"
        case .attachments: "Prílohy"
        case .contacts: "Adresár"
        }
    }

    func subtitle(for item: SidebarItem?) -> String? {
        if case .folder(let a, _) = item { return account(a)?.email }
        return nil
    }

    // MARK: Sidebar state

    func isExpanded(_ a: Account) -> Binding<Bool> {
        Binding(get: { self.expandedAccounts.contains(a.id) }, set: { on in
            guard on != self.expandedAccounts.contains(a.id) else { return }
            if on { self.expandedAccounts.insert(a.id) } else { self.expandedAccounts.remove(a.id) }
        })
    }

    /// Open/closed state of sidebar groups. Keys: "p:<project>", "a:<project or ->:<account>". Stored as the
    /// keys that differ from their default.
    func isExpanded(key: String, default def: Bool) -> Binding<Bool> {
        Binding(get: { self.expandedAccounts.contains(key) != def }, set: { on in
            let flipped = on != def
            guard flipped != self.expandedAccounts.contains(key) else { return }
            if flipped { self.expandedAccounts.insert(key) } else { self.expandedAccounts.remove(key) }
        })
    }

    /// Accounts that are in no project (as a whole mailbox).
    var unassignedAccounts: [Account] {
        let assigned = Set(projects.flatMap { $0.sources.filter { $0.kind == .account }.compactMap(\.accountID) })
        return accounts.filter { !assigned.contains($0.id) }
    }

    func handleDrop(_ providers: [NSItemProvider], onto projectID: String?) -> Bool {
        var accepted = false
        for p in providers where p.canLoadObject(ofClass: NSString.self) {
            accepted = true
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let payload = obj as? String else { return }
                Task { @MainActor in self.drop(payload, onto: projectID) }
            }
        }
        return accepted
    }

    /// A mailbox moves (out of every other project, into the target or to "Nezaradené"); a folder is added.
    func drop(_ payload: String, onto projectID: String?) {
        if payload.hasPrefix("message:") { return }   // mails go to tickets, not into projects
        if payload.hasPrefix("account:") {
            let accountID = String(payload.dropFirst(8).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            for var p in projects where p.sources.contains(where: { $0.kind == .account && $0.accountID == accountID }) && p.id != projectID {
                p.sources.removeAll { $0.kind == .account && $0.accountID == accountID }
                try? store.save(p)
            }
            projects = store.projects()
            if let projectID, let target = projects.first(where: { $0.id == projectID }) {
                _ = addSource("account:\(accountID)", to: target)
                expandedAccounts.remove("p:" + projectID)   // make sure the target is open (default is open)
            }
            loadMessages()
        } else if let projectID, let target = projects.first(where: { $0.id == projectID }) {
            _ = addSource(payload, to: target)
        }
    }

    /// Drop on a mailbox row: the dragged mailbox goes right before it (same project = reorder, other place = move there).
    /// A project dropped on a project row goes before it.
    func handleDrop(_ providers: [NSItemProvider], project projectID: String?, before accountID: String) -> Bool {
        loadPayloads(providers) { payload in self.place(payload, project: projectID, before: accountID) }
    }

    func handleProjectDrop(_ providers: [NSItemProvider], onto projectID: String) -> Bool {
        loadPayloads(providers) { payload in
            if payload.hasPrefix("project:") { self.moveProject(String(payload.dropFirst(8)), before: projectID) }
            else { self.drop(payload, onto: projectID) }
        }
    }

    /// A mail dragged from the list onto a ticket status or a tag in the sidebar (or a column on the board).
    func handleMessageDrop(_ providers: [NSItemProvider], status: TicketStatus? = nil, tag: String? = nil) -> Bool {
        loadPayloads(providers) { payload in
            guard let m = self.droppedMessage(payload) else { return }
            if let status { self.setStatus(status, for: m) }
            if let tag, !(self.tickets[m.threadKey]?.tags.contains(tag) ?? false) { self.toggleTag(tag, for: m) }
        }
    }

    func droppedMessage(_ payload: String) -> MessageSummary? {
        guard payload.hasPrefix("message:"), let id = Int64(payload.dropFirst(8)) else { return nil }
        return store.message(id: id)
    }

    private func loadPayloads(_ providers: [NSItemProvider], _ each: @escaping @MainActor (String) -> Void) -> Bool {
        var accepted = false
        for p in providers where p.canLoadObject(ofClass: NSString.self) {
            accepted = true
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let payload = obj as? String else { return }
                Task { @MainActor in each(payload) }
            }
        }
        return accepted
    }

    func place(_ payload: String, project projectID: String?, before target: String) {
        guard payload.hasPrefix("account:") else {
            if let projectID { drop(payload, onto: projectID) }
            return
        }
        let moving = String(payload.dropFirst(8).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard moving != target else { return }
        if let projectID {
            // Out of every other project, then into this one right before the target.
            for var p in projects where p.id != projectID && p.sources.contains(where: { $0.kind == .account && $0.accountID == moving }) {
                p.sources.removeAll { $0.kind == .account && $0.accountID == moving }
                try? store.save(p)
            }
            projects = store.projects()
            guard var p = projects.first(where: { $0.id == projectID }) else { return }
            let src = p.sources.first { $0.kind == .account && $0.accountID == moving } ?? ProjectSource(kind: .account, accountID: moving)
            p.sources.removeAll { $0 == src }
            let i = p.sources.firstIndex { $0.kind == .account && $0.accountID == target } ?? p.sources.count
            p.sources.insert(src, at: i)
            try? store.save(p)
            projects = store.projects()
        } else {
            drop(payload, onto: nil)   // into "Nezaradené" first
            var order = accounts.sorted { $0.sort < $1.sort }.map(\.id)
            order.removeAll { $0 == moving }
            order.insert(moving, at: order.firstIndex(of: target) ?? order.count)
            for (i, id) in order.enumerated() { if var a = account(id) { a.sort = i; try? store.save(a) } }
            accounts = store.accounts()
        }
        loadMessages()
    }

    func moveProject(_ id: String, before target: String) {
        guard id != target else { return }
        var list = projects
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let p = list.remove(at: from)
        list.insert(p, at: list.firstIndex { $0.id == target } ?? list.count)
        for (i, var x) in list.enumerated() { x.sort = i; try? store.save(x) }
        projects = store.projects()
    }

    func renameAccount(_ a: Account, to name: String) {
        var a = a
        let n = name.trimmingCharacters(in: .whitespaces)
        a.name = n.isEmpty ? a.email : n
        try? store.save(a)
        accounts = store.accounts()
    }

    func removeSource(_ src: ProjectSource, from p: Project) {
        var p = p
        p.sources.removeAll { $0 == src }
        save(p)
    }

    /// Drag payloads from the sidebar: "account:<id>" or "folder:<id>\u{1}<path>".
    func addSource(_ payload: String, to project: Project) -> Bool {
        var p = project
        let src: ProjectSource
        if payload.hasPrefix("account:") {
            src = ProjectSource(kind: .account, accountID: String(payload.dropFirst(8).split(separator: "|").first ?? ""))
        } else if payload.hasPrefix("folder:") {
            let parts = payload.dropFirst(7).split(separator: "\u{1}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            let f = folder(parts[0], parts[1])
            src = f?.role == .inbox ? ProjectSource(kind: .account, accountID: parts[0]) : ProjectSource(kind: .folder, accountID: parts[0], folder: parts[1])
        } else { return false }
        guard !p.sources.contains(src) else { return true }
        p.sources.append(src)
        save(p)
        return true
    }

    // MARK: Sync

    private func selectionChanged() {
        selectedMessageID = nil
        category = nil
        loadMessages()
        if case .folder(let a, let p) = selection, let acc = account(a) {
            Task {
                do { try await sync.syncMessages(acc, folder: p); accountErrors[a] = nil } catch { accountErrors[a] = error.localizedDescription }
                folders = Dictionary(grouping: store.folders(), by: \.accountID)
                loadMessages()
                await sync.prefetchBodies(acc, folder: p, limit: 25)
                loadMessages()
            }
        }
    }

    func refreshAll() async {
        guard !syncing else { return }
        syncing = true
        accountErrors = await sync.syncAll()
        syncing = false
        reload()
        await notifyArrived()
        startBackfill()
    }

    /// Light check: only the inboxes.
    func checkInboxes() async {
        guard !syncing else { return }
        for a in accounts {
            guard let inbox = folders[a.id]?.first(where: { $0.role == .inbox }) else { continue }
            do { try await sync.syncMessages(a, folder: inbox.path); accountErrors[a.id] = nil } catch { accountErrors[a.id] = error.localizedDescription }
        }
        folders = Dictionary(grouping: store.folders(), by: \.accountID)
        loadMessages()
        await notifyArrived()
    }

    func notifyArrived() async {
        let ids = await sync.drainArrived()
        Notifier.shared.post(ids.compactMap(store.message), accounts: accounts)
        Notifier.shared.updateBadge(store)
    }

    /// Older history in the background, a batch at a time; the list refreshes as it goes.
    func startBackfill() {
        guard !backfilling else { return }
        backfilling = true
        Task {
            // History arrives in many small batches: reloading the whole list on each one made the list jump under the
            // cursor (clicks landed on another row) and the app sluggish. Status and list refresh at most every 2 s.
            let report: @Sendable (String) -> Void = { s in Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(self.lastBackfillReload) > 2 else { return }
                self.lastBackfillReload = Date()
                self.backfillStatus = s
                self.loadMessages()
            } }
            await sync.backfillAll(progress: report)
            backfilling = false
            backfillStatus = ""
            loadMessages()
        }
    }

    func refresh(account a: Account) async {
        do {
            try await sync.syncFolders(a)
            for f in store.folders(account: a.id) where f.selectable && [.inbox, .sent].contains(f.role) {
                try await sync.syncMessages(a, folder: f.path)
            }
            accountErrors[a.id] = nil
        } catch { accountErrors[a.id] = error.localizedDescription }
        reload()
    }

    // MARK: Conversation

    private func openSelected() {
        let before = openThread
        guard let m = selectedMessage else {
            conversation = []; expanded = []; openThread = nil
            if unreadOnly, before != nil { loadMessages() }
            return
        }
        openThread = m.threadKey
        // the conversation read before now leaves the Unread list (it stayed while it was open)
        if unreadOnly, let b = before, b != m.threadKey { loadMessages() }
        var thread = store.thread(account: m.accountID, id: m.threadID)
        if thread.isEmpty { thread = [m] }
        // Newest message and every unread one open; the rest stay as one-line summaries.
        var open = Set(thread.filter { !$0.seen }.map(\.id))
        if let last = thread.last { open.insert(last.id) }
        // Switching conversations swaps the pane at once (animating it made arrowing through mail jittery).
        conversation = thread
        expanded = open
        for id in expanded { loadBody(id) }
        let unread = thread.filter { !$0.seen }
        if !unread.isEmpty { markReadNow(unread, thread: m.threadKey) }
    }

    /// Opening marks read right away on screen and in the cache; the server is told in the background.
    /// No list reload: only the affected rows change, so nothing jumps under the cursor.
    private func markReadNow(_ unread: [MessageSummary], thread key: String) {
        let ids = Set(unread.map(\.id))
        for u in unread { try? store.setSeen(id: u.id, true) }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            conversation = conversation.map { var x = $0; if ids.contains(x.id) { x.seen = true }; return x }
            if let i = messages.firstIndex(where: { $0.threadKey == key }) { messages[i].seen = true }
            if var st = threadStats[key] { st.unread = 0; threadStats[key] = st }
            for (_, list) in Dictionary(grouping: unread, by: { "\($0.accountID)\u{1}\($0.folder)" }) {
                if let f = list.first { adjustUnread(f, by: -list.count) }
            }
        }
        Task { for u in unread { try? await sync.setSeen(u, true) } }
    }

    func toggleExpanded(_ m: MessageSummary) {
        withAnimation(.snappy(duration: 0.22)) {
            if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
        }
        if expanded.contains(m.id) { loadBody(m.id) }
    }

    func loadBody(_ id: Int64) {
        guard bodies[id] == nil else { return }
        if let b = store.body(id: id) { bodies[id] = b; return }
        guard let m = conversation.first(where: { $0.id == id }) ?? store.message(id: id) else { return }
        Task {
            do { bodies[id] = try await sync.fetchBody(m); bodyErrors[id] = nil } catch { bodyErrors[id] = error.localizedDescription }
        }
    }

    func toggleSeen(_ m: MessageSummary) {
        Task {
            try? await sync.setSeen(m, !m.seen)
            adjustUnread(m, by: m.seen ? 1 : -1)
            loadMessages()
        }
    }

    private func adjustUnread(_ m: MessageSummary, by d: Int) {
        guard var list = folders[m.accountID], let i = list.firstIndex(where: { $0.path == m.folder }) else { return }
        list[i].unread = max(0, list[i].unread + d)
        try? store.setCounts(account: m.accountID, folder: m.folder, unread: list[i].unread, total: list[i].total)
        folders[m.accountID] = list
        Notifier.shared.updateBadge(store)
    }

    // MARK: Tickets

    func setStatus(_ s: TicketStatus?, for m: MessageSummary) {
        var t = tickets[m.threadKey] ?? Ticket(accountID: m.accountID, threadID: m.threadID)
        t.status = s
        try? store.save(t)
        tickets = store.tickets()
        loadMessages()
    }

    func toggleTag(_ name: String, for m: MessageSummary) {
        var t = tickets[m.threadKey] ?? Ticket(accountID: m.accountID, threadID: m.threadID)
        if t.tags.contains(name) { t.tags.removeAll { $0 == name } } else { t.tags.append(name) }
        try? store.save(t)
        tickets = store.tickets()
        loadMessages()
    }

    func createTag(_ name: String, color: String, apply m: MessageSummary?) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        try? store.save(Tag(name: n, color: color))
        tags = store.tags()
        if let m, !(tickets[m.threadKey]?.tags.contains(n) ?? false) { toggleTag(n, for: m) }
    }

    func deleteTag(_ name: String) {
        try? store.deleteTag(name)
        if selection == .tag(name) { selection = .unified }
        tags = store.tags()
        tickets = store.tickets()
        loadMessages()
    }

    // MARK: Accounts

    func addAccount(email: String, name: String, config: DiscoveredConfig, secret: String) async throws {
        let client = try await MailSync.connect(config.imap, secret: secret)
        await client.logout()
        let a = Account(email: email, name: name.isEmpty ? email : name, imap: config.imap, smtp: config.smtp, sort: accounts.count)
        try Keychain.set(secret, for: a.id)
        try store.save(a)
        expandedAccounts.insert(a.id)
        reload()
        await refresh(account: a)
        if let inbox = store.folders(account: a.id).first(where: { $0.role == .inbox }) {
            selection = .folder(account: a.id, path: inbox.path)
        }
        startBackfill()
    }

    func removeAccount(_ a: Account) {
        Task {
            await sync.disconnect(a.id)
            try? store.deleteAccount(a.id)
            Keychain.delete(a.id)
            if case .folder(let id, _) = selection, id == a.id { selection = .unified }
            reload()
        }
    }

    // MARK: Projects

    func save(_ p: Project) {
        var p = p
        if !projects.contains(where: { $0.id == p.id }) { p.sort = projects.count }
        try? store.save(p)
        projects = store.projects()
        loadMessages()
    }

    func delete(_ p: Project) {
        try? store.deleteProject(p.id)
        if selection == .project(p.id) { selection = .board }
        projects = store.projects()
    }

    func move(projects from: IndexSet, to: Int) {
        var list = projects
        list.move(fromOffsets: from, toOffset: to)
        for (i, var p) in list.enumerated() { p.sort = i; try? store.save(p) }
        projects = store.projects()
    }
}

struct CategoryBundle: Identifiable, Equatable {
    var category: MailCategory
    var date: Date
    var count: Int
    var unread: Int
    var senders: [String]
    var id: String { category.rawValue }
}
