import CourierCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            // The board opens projects, not messages: it gets the whole width, without the reading column next to it.
            if model.selection == .board && model.search.isEmpty {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                } detail: {
                    BoardView()
                }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                } content: {
                    Group {
                        if model.selection == .outbox { OutboxView() }
                        else if model.selection == .attachments { AttachmentsView() }
                        else if model.selection == .contacts { AddressBookView() }
                        else { MessageListView() }
                    }
                    .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 540)
                } detail: {
                    if model.selection == .contacts { ContactDetailView() } else { ConversationView() }
                }
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: model.selection == .contacts ? "Hľadať meno alebo e-mail" : "Hľadať v pošte")
        .focusEffectDisabled()
        .onAppear { MainWindow.open = { [openWindow] in openWindow(id: "main") } }
        .onReceive(NotificationCenter.default.publisher(for: .courierURL)) { n in
            guard let u = n.object as? URL else { return }
            NSApp.activate()
            switch u.host {
            case "compose": openWindow(id: "compose", value: model.newDraft())
            case "message":   // courier://message/<id> (links in Brain's morning brief)
                if let id = Int64(u.lastPathComponent), let m = model.store.message(id: id) { model.show(m) }
            default: model.selection = .unified
            }
        }
        .overlay(alignment: .bottom) {
            if let u = model.undo { UndoBar(undo: u).padding(.bottom, 18).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.snappy, value: model.undo)
        .overlay(alignment: .top) {
            if let c = model.copiedText { CopiedToast(text: c).padding(.top, 12).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .animation(.snappy, value: model.copiedText)
        .sheet(item: $model.preview) { p in PreviewSheet(p: p) }
        .sheet(isPresented: $model.showAddAccount) { AddAccountView() }
        .sheet(item: $model.editingProject) { p in ProjectEditor(project: p) }
    }
}

// MARK: Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @State private var dropTarget: String?

    var body: some View {
        List {
            Section {
                row("Všetky doručené", symbol: "tray.2", tint: .accentColor, badge: model.unifiedUnread).sidebarItem(SidebarItem.unified)
                ForEach(AppModel.unifiedRoles.filter { AppModel.unifiedShown($0) && model.availableRoles.contains($0) }, id: \.self) { r in
                    row(AppModel.unifiedTitle(r), symbol: r.symbol, tint: .accentColor, badge: model.unifiedCount(r)).sidebarItem(SidebarItem.role(r))
                }
                row("Prílohy", symbol: "paperclip", tint: .secondary, badge: 0).sidebarItem(SidebarItem.attachments)
                if model.showContactsTab {
                    row("Adresár", symbol: "person.crop.rectangle.stack", tint: .secondary, badge: 0).sidebarItem(SidebarItem.contacts)
                        .contextMenu { Button("Skryť z bočného panela") { model.showContactsTab = false } }
                }
                if !model.outbox.isEmpty {
                    row("Na odoslanie", symbol: model.outbox.contains { $0.error != nil } ? "exclamationmark.triangle" : "clock",
                        tint: model.outbox.contains { $0.error != nil } ? .orange : .secondary, badge: model.outbox.count)
                        .sidebarItem(SidebarItem.outbox)
                }
            }

            Section("Projekty") {
                tree(level: 0, expanded: nil) { Label("Nástenka", systemImage: "square.grid.2x2") }
                    .sidebarItem(SidebarItem.board)
                ForEach(model.projects) { p in projectRows(p) }
                tree(level: 0, expanded: nil) {
                    Button { model.editingProject = Project(name: "") } label: {
                        Label("Nový projekt", systemImage: "plus").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            let loose = model.unassignedAccounts
            if !loose.isEmpty || !model.projects.isEmpty {
                Section {
                    ForEach(loose) { a in accountRows(a, in: nil, level: 0) }
                    if loose.isEmpty { dropHint("Pretiahni sem schránku", target: "none", level: 0) }
                } header: {
                    Text(model.projects.isEmpty ? "Schránky" : "Nezaradené")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(dropTarget == "none" ? Color.secondary.opacity(0.15) : .clear, in: .rect(cornerRadius: 5))
                        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: target("none")) { model.handleDrop($0, onto: nil) }
                }
            }

            Section("Tikety") {
                ForEach(TicketStatus.allCases, id: \.self) { s in
                    row(s.title, symbol: s.symbol, tint: s == .done ? .green : (s == .waiting ? .orange : .blue), badge: s == .done ? 0 : model.count(s))
                        .sidebarItem(SidebarItem.status(s))
                        .background(dropTarget == "st:\(s.rawValue)" ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
                        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: target("st:\(s.rawValue)")) { model.handleMessageDrop($0, status: s) }
                }
                ForEach(model.tags) { t in
                    Label { Text(t.name).lineLimit(1) } icon: { SidebarIcon(symbol: "tag.fill", tint: ProjectColor.of(t.color)) }
                        .sidebarItem(SidebarItem.tag(t.name))
                        .background(dropTarget == "tag:\(t.name)" ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
                        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: target("tag:\(t.name)")) { model.handleMessageDrop($0, tag: t.name) }
                        .contextMenu { Button("Odstrániť štítok „\(t.name)“", role: .destructive) { model.deleteTag(t.name) } }
                }
            }
        }
        .listStyle(.sidebar)
        // A bar (not a plain inset): rows scrolling under "Pridať účet" get blurred instead of showing through.
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .safeAreaBar(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if !model.backfillStatus.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("História: \(model.backfillStatus)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack {
                    Button { model.showAddAccount = true } label: { Label("Pridať účet", systemImage: "person.crop.circle.badge.plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                    if model.syncing { ProgressView().controlSize(.small) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    func target(_ id: String) -> Binding<Bool> {
        Binding(get: { dropTarget == id }, set: { dropTarget = $0 ? id : (dropTarget == id ? nil : dropTarget) })
    }

    func dropHint(_ text: String, target id: String, level: Int) -> some View {
        tree(level: level, expanded: nil) {
            Text(text).font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: target(id)) { model.handleDrop($0, onto: id == "none" ? nil : id) }
    }

    /// A tree row with our own disclosure chevron inside it, so the selection covers the chevron too.
    func tree<C: View>(level: Int, expanded: Binding<Bool>?, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 3) {
            if let expanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.18)) { expanded.wrappedValue.toggle() } }
            } else {
                Color.clear.frame(width: 14, height: 18)
            }
            content()
        }
        .padding(.leading, CGFloat(level) * 14)
    }

    /// A project, then (when open) its mailboxes and folders.
    @ViewBuilder func projectRows(_ p: Project) -> some View {
        let open = model.isExpanded(key: "p:" + p.id, default: true)
        tree(level: 0, expanded: open) {
            row(p.name, symbol: p.symbol, tint: ProjectColor.of(p.color), badge: model.unread(project: p))
        }
        .sidebarItem(SidebarItem.project(p.id))
        .onDrag({ NSItemProvider(object: "project:\(p.id)" as NSString) }, preview: { DragCard(title: p.name, subtitle: p.name, symbol: p.symbol) })
        .overlay {
            if dropTarget == p.id {
                RoundedRectangle(cornerRadius: 8).fill(ProjectColor.of(p.color).opacity(0.2))
                    .padding(.leading, -6).padding(.trailing, -2).padding(.vertical, -6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: target(p.id)) { model.handleProjectDrop($0, onto: p.id) }
        .contextMenu {
            Button("Upraviť projekt…") { model.editingProject = p }
            Button("Odstrániť projekt", role: .destructive) { model.delete(p) }
        }
        if open.wrappedValue {
            ForEach(Array(p.sources.enumerated()), id: \.offset) { _, src in sourceRows(src, in: p) }
            if p.sources.isEmpty { dropHint("Pretiahni sem schránku", target: p.id, level: 1) }
        }
    }

    /// A mailbox (the row opens its inbox), then (when open) its other folders. Lives in exactly one place:
    /// under its project, or under "Nezaradené".
    @ViewBuilder func accountRows(_ a: Account, in project: Project?, level: Int) -> some View {
        let folders = (model.folders[a.id] ?? []).filter(\.selectable)
        let inbox = folders.first { $0.role == .inbox }
        let payload = "account:\(a.id)|\(project?.id ?? "")"
        let open = model.isExpanded(key: "a:\(project?.id ?? "-"):\(a.id)", default: false)
        tree(level: level, expanded: open) {
            row(a.name == a.email ? a.email : a.name, symbol: "tray", tint: project.map { ProjectColor.of($0.color) } ?? .accentColor, badge: inbox?.unread ?? 0)
            if model.accountErrors[a.id] != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(model.accountErrors[a.id] ?? "")
            }
        }
        .help(a.email)
        .sidebarItem(inbox.map { SidebarItem.folder(account: a.id, path: $0.path) } ?? SidebarItem.unified)
        .onDrag({ NSItemProvider(object: payload as NSString) }, preview: { DragCard(title: a.name == a.email ? a.email : a.name, subtitle: a.email, symbol: "tray.fill") })
        // Dropping another mailbox here puts it right above this one; the line shows where.
        .overlay(alignment: .top) {
            if dropTarget == "acc:\(project?.id ?? "-"):\(a.id)" {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -7).padding(.leading, CGFloat(level) * 14).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: target("acc:\(project?.id ?? "-"):\(a.id)")) {
            model.handleDrop($0, project: project?.id, before: a.id)
        }
        .contextMenu {
            Button("Nová správa z \(a.email)") { openWindow(id: "compose", value: model.newDraft(account: a.id)) }
            Button("Premenovať…") { RenamePanel.ask(title: "Premenovať schránku", value: a.name == a.email ? "" : a.name, placeholder: a.email) { model.renameAccount(a, to: $0) } }
            addToProjectMenu(payload, move: true)
            Button("Obnoviť") { Task { await model.refresh(account: a) } }
            Divider()
            Button("Odstrániť účet \(a.email)", role: .destructive) { model.removeAccount(a) }
        }
        if open.wrappedValue {
            ForEach(folders.filter { $0.role != .inbox }) { f in
                let extra = f.role == .other ? max(0, f.depth - (f.path.uppercased().hasPrefix("INBOX") ? 1 : 0)) : 0
                tree(level: level + 1 + extra, expanded: nil) {
                    row(f.displayName, symbol: f.role.symbol, tint: .secondary, badge: [.junk, .trash, .sent, .drafts].contains(f.role) ? 0 : f.unread)
                }
                .sidebarItem(SidebarItem.folder(account: a.id, path: f.path))
                .onDrag({ NSItemProvider(object: "folder:\(a.id)\u{1}\(f.path)" as NSString) }, preview: { DragCard(title: f.displayName, subtitle: a.email, symbol: f.role.symbol) })
                .contextMenu { addToProjectMenu("folder:\(a.id)\u{1}\(f.path)", move: false) }
            }
        }
    }

    /// A project's source, nested under it in the sidebar.
    @ViewBuilder func sourceRows(_ src: ProjectSource, in p: Project) -> some View {
        switch src.kind {
        case .account:
            if let a = model.account(src.accountID ?? "") { accountRows(a, in: p, level: 1) }
        case .folder:
            if let f = model.folder(src.accountID ?? "", src.folder ?? "") {
                tree(level: 1, expanded: nil) {
                    row(f.displayName, symbol: f.role.symbol, tint: .secondary, badge: f.unread)
                }
                .help(model.account(f.accountID)?.email ?? "")
                .sidebarItem(SidebarItem.folder(account: f.accountID, path: f.path))
                .contextMenu { Button("Odobrať z projektu") { model.removeSource(src, from: p) } }
            }
        case .sender:
            tree(level: 1, expanded: nil) { Label(src.pattern ?? "", systemImage: "person").foregroundStyle(.secondary) }
                .contextMenu { Button("Odobrať z projektu") { model.removeSource(src, from: p) } }
        }
    }

    @ViewBuilder func addToProjectMenu(_ payload: String, move: Bool) -> some View {
        if !model.projects.isEmpty {
            Menu(move ? "Presunúť do projektu" : "Pridať do projektu") {
                ForEach(model.projects) { p in Button(p.name) { model.drop(payload, onto: p.id) } }
                if move { Divider(); Button("Nezaradené") { model.drop(payload, onto: nil) } }
            }
        }
    }

    func row(_ title: String, symbol: String, tint: Color, badge: Int) -> some View {
        HStack(spacing: 6) {
            Label { Text(title).lineLimit(1) } icon: { SidebarIcon(symbol: symbol, tint: tint) }
            Spacer(minLength: 4)
            if badge > 0 { Text("\(badge)").font(.callout).monospacedDigit().foregroundStyle(.secondary) }
        }
        .padding(.trailing, 6)
    }
}

/// Sidebar icon in its own color (selection never recolors it).
struct SidebarIcon: View {
    let symbol: String
    let tint: Color
    var body: some View { Image(systemName: symbol).foregroundStyle(tint) }
}

/// What you hold while dragging a mailbox or folder: a small tilted card.
struct DragCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline)
                if subtitle != title { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .fixedSize()
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .rotationEffect(.degrees(-3))
        // Room around the card so the shadow and the tilt are not cut by the preview's bounds.
        .padding(28)
    }
}

// MARK: Conversation list (chat style)

struct MessageListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow

    var showsAccount: Bool {
        if case .folder = model.selection, model.search.isEmpty { return false }
        return model.accounts.count > 1
    }

    enum Row: Identifiable {
        case message(MessageSummary)
        case bundle(CategoryBundle)
        var id: String { switch self { case .message(let m): "m\(m.id)"; case .bundle(let b): "b" + b.id } }
        var date: Date { switch self { case .message(let m): m.date; case .bundle(let b): b.date } }
    }

    /// People's conversations with the group rows placed by their newest message.
    var rows: [Row] {
        (model.messages.map(Row.message) + model.bundles.map(Row.bundle)).sorted { $0.date > $1.date }
    }

    var body: some View {
        List(selection: $model.selectedIDs) {
            ForEach(rows) { r in
                switch r {
                case .bundle(let b):
                    BundleRow(b: b)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { model.category = b.category } }
                        .contextMenu {
                            Button("Otvoriť") { model.category = b.category }
                            Button("Označiť všetko ako prečítané") { model.markRead(b.category) }.disabled(b.unread == 0)
                        }
                case .message(let m):
                    MessageRow(m: m, account: showsAccount ? model.account(m.accountID) : nil)
                        .tag(m.id)
                        .softSelection(model.selectedIDs.contains(m.id))
                        // List's own drag (not onDrag): a gesture on the row competes with the click that selects it.
                        .itemProvider { NSItemProvider(object: "message:\(m.id)" as NSString) }
                        .contextMenu {
                            if model.selectedIDs.count > 1 && model.selectedIDs.contains(m.id) {
                                BulkActionsMenu()
                            } else {
                            ReplyMenu(m: m)
                            Divider()
                            MessageActionsMenu(m: m)
                            Divider()
                            TicketMenu(m: m)
                            Menu("Odosielateľ patrí do") {
                                ForEach(MailCategory.allCases) { c in
                                    Toggle(c.title, isOn: Binding(get: { m.category == c }, set: { _ in model.setSenderCategory(m, c) }))
                                }
                                if model.store.overrides[m.fromAddress.lowercased()] != nil {
                                    Divider()
                                    Button("Automaticky") { model.setSenderCategory(m, nil) }
                                }
                            }
                            Button(model.isUnread(m) ? "Označiť ako prečítané" : "Označiť ako neprečítané") { model.toggleSeen(m) }
                            }
                        }
                }
            }
        }
        .listStyle(.inset)
        .background(NoTableHighlight())
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.groupsApply && !model.categoryCounts.isEmpty { GroupChips() }
        }
        .onDeleteCommand {
            if model.selectedIDs.count > 1 { model.deleteSelected() } else if let m = model.selectedMessage { model.delete(m) }
        }
        .contextMenu(forSelectionType: Int64.self) { _ in } primaryAction: { ids in
            // Double-click on a draft opens it for editing.
            if let id = ids.first, let m = model.messages.first(where: { $0.id == id }), model.isDraft(m) {
                model.openDraft(m) { openWindow(id: "compose", value: $0) }
            }
        }
        .overlay {
            if model.messages.isEmpty && model.bundles.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "Žiadne správy" : "Nič sa nenašlo",
                                       systemImage: model.search.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(model.accounts.isEmpty ? "Pridaj si prvý účet." : ""))
            }
        }
        .navigationTitle(model.search.isEmpty ? model.title(for: model.selection) : "Hľadanie")
        .navigationSubtitle(model.subtitle(for: model.selection) ?? "")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $model.unreadOnly) { Label("Len neprečítané", systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Len neprečítané")
                Button { Task { await model.refreshAll() } } label: { Label("Obnoviť", systemImage: "arrow.clockwise") }
                    .disabled(model.syncing)
                Button { openWindow(id: "compose", value: model.newDraft()) } label: { Label("Nová správa", systemImage: "square.and.pencil") }
                    .help("Nová správa (⌘N)")
            }
        }
    }
}

struct MessageRow: View {
    @EnvironmentObject var model: AppModel
    let m: MessageSummary
    let account: Account?

    var body: some View {
        let unread = model.isUnread(m)
        let count = model.threadStats[m.threadKey]?.count ?? 1
        let ticket = model.ticket(m)
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: m.fromName, address: m.fromAddress)
                .overlay(alignment: .topLeading) {
                    if unread { Circle().fill(.blue).frame(width: 9, height: 9).offset(x: -3, y: -1) }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(m.fromDisplay).font(.headline.weight(unread ? .bold : .medium)).lineLimit(1)
                    if count > 1 {
                        Text("\(count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: .capsule)
                    }
                    Spacer(minLength: 6)
                    if m.flagged { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.orange) }
                    if m.hasAttachments { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary) }
                    Text(m.date.listLabel).font(.caption).foregroundStyle(unread ? Color.blue : .secondary)
                }
                Text(m.subject.isEmpty ? "(bez predmetu)" : m.subject)
                    .font(.subheadline.weight(unread ? .semibold : .regular)).lineLimit(1)
                if !m.snippet.isEmpty {
                    Text(m.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if ticket != nil || account != nil {
                    HStack(spacing: 4) {
                        if let s = ticket?.status { StatusPill(status: s) }
                        ForEach(ticket?.tags ?? [], id: \.self) { TagChip(name: $0, color: model.tag($0)?.color ?? "gray") }
                        if let account { Text(account.email).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())   // the whole row is clickable, also the empty space between texts
    }
}

struct StatusPill: View {
    let status: TicketStatus
    var tint: Color { status == .done ? .green : (status == .waiting ? .orange : .blue) }
    var body: some View {
        Label(status.title, systemImage: status.symbol).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.14), in: .capsule)
    }
}

struct TagChip: View {
    let name: String
    let color: String
    var body: some View {
        Text(name).font(.caption2.weight(.medium)).foregroundStyle(ProjectColor.of(color))
            .padding(.horizontal, 6).padding(.vertical, 2).background(ProjectColor.of(color).opacity(0.14), in: .capsule)
    }
}

/// Status and tags of a conversation (used in context menus and the conversation header).
struct TicketMenu: View {
    @EnvironmentObject var model: AppModel
    let m: MessageSummary
    @State private var newTag = false

    var body: some View {
        let t = model.ticket(m)
        Menu("Stav") {
            ForEach(TicketStatus.allCases, id: \.self) { s in
                Toggle(s.title, isOn: Binding(get: { t?.status == s }, set: { model.setStatus($0 ? s : nil, for: m) }))
            }
            if t?.status != nil { Divider(); Button("Bez stavu") { model.setStatus(nil, for: m) } }
        }
        Menu("Štítky") {
            ForEach(model.tags) { tag in
                Toggle(tag.name, isOn: Binding(get: { t?.tags.contains(tag.name) ?? false }, set: { _ in model.toggleTag(tag.name, for: m) }))
            }
            if !model.tags.isEmpty { Divider() }
            Button("Nový štítok…") { NewTagPanel.ask { name, color in model.createTag(name, color: color, apply: m) } }
        }
    }
}

struct ReplyMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    let m: MessageSummary
    var body: some View {
        Button("Odpovedať") { openWindow(id: "compose", value: model.replyDraft(m, .reply)) }
        Button("Odpovedať všetkým") { openWindow(id: "compose", value: model.replyDraft(m, .replyAll)) }
        Button("Preposlať") { openWindow(id: "compose", value: model.replyDraft(m, .forward)) }
    }
}

/// Small AppKit prompt for a tag name (menus can't host text fields).
enum NewTagPanel {
    @MainActor static func ask(_ done: @escaping (String, String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Nový štítok"
        alert.informativeText = "Napr. Faktúra, Čaká na klienta, Dôležité."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Názov štítka"
        alert.accessoryView = field
        alert.addButton(withTitle: "Vytvoriť")
        alert.addButton(withTitle: "Zrušiť")
        alert.window.initialFirstResponder = field
        let colors = ["blue", "purple", "pink", "orange", "green", "teal", "red", "indigo"]
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { done(name, colors[abs(name.hashValue) % colors.count]) }
        }
    }
}

/// Sidebar selection drawn by us: the row keeps its colors and gets a soft grey background, also while focused.
struct SidebarSelection: ViewModifier {
    @EnvironmentObject var model: AppModel
    let item: SidebarItem
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.selection = item }
            // Drawn on the row's own content (a list row background drifts to the neighbouring row inside disclosure groups).
            .background {
                if model.selection == item {
                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.09))
                        .padding(.leading, -6).padding(.trailing, -2).padding(.vertical, -6)
                }
            }
    }
}

extension View {
    func sidebarItem(_ item: SidebarItem) -> some View { modifier(SidebarSelection(item: item)) }
}

/// One row standing for a whole group (newsletters, notifications…), Spark-like but one line and placed by time.
struct BundleRow: View {
    let b: CategoryBundle
    var body: some View {
        let tint = ProjectColor.of(b.category.colorName)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: b.category.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(b.category.title).font(.headline.weight(b.unread > 0 ? .bold : .medium))
                    if b.unread > 0 {
                        Text("\(b.unread) nové").font(.caption.weight(.semibold)).foregroundStyle(tint)
                    }
                    Spacer()
                    Text(b.date.listLabel).font(.caption).foregroundStyle(.secondary)
                }
                Text(b.senders.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

/// Filter chips above the list: overview, then each group with its unread count.
struct GroupChips: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(nil, "Prehľad", "square.stack", unread: 0)
                ForEach(MailCategory.allCases.filter { model.categoryCounts[$0] != nil }) { c in
                    chip(c, c.title, c.symbol, unread: model.categoryCounts[c]?.unread ?? 0)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    func chip(_ c: MailCategory?, _ title: String, _ symbol: String, unread: Int) -> some View {
        let on = model.category == c
        return Button { withAnimation(.snappy(duration: 0.2)) { model.category = c } } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(title)
                if unread > 0 { Text("\(unread)").monospacedDigit().foregroundStyle(on ? .primary : .secondary) }
            }
            .font(.callout.weight(on ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(on ? Color.primary.opacity(0.1) : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Small AppKit prompt for one line of text.
enum RenamePanel {
    @MainActor static func ask(title: String, value: String, placeholder: String, info: String = "Meno sa zobrazuje v lište a ako meno odosielateľa.", _ done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "Uložiť")
        alert.addButton(withTitle: "Zrušiť")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { done(field.stringValue) }
    }
}
