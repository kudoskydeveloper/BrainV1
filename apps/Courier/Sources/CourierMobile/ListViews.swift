#if os(iOS)
import SwiftUI
import CourierCore

/// Unified inbox of all accounts, one row per conversation, filtered by the smart groups.
struct InboxView: View {
    @Environment(MobileModel.self) private var model
    @State private var category: MailCategory?
    @State private var unreadOnly = false
    @State private var composing = false
    @State private var addingAccount = false

    var shown: [MessageSummary] {
        model.inbox.filter { (category == nil || $0.category == category) && (!unreadOnly || model.unread($0)) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("Žiadna schránka", systemImage: "envelope.badge")
                    } description: {
                        Text("Pridaj e-mailový účet. Nastavenia servera Courier nájde sám.")
                    } actions: {
                        Button("Pridať účet") { addingAccount = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    MessageList(messages: shown, header: AnyView(filters))
                }
            }
            .navigationTitle(category?.title ?? "Doručené")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { unreadOnly.toggle() } label: {
                        Image(systemName: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(model.accounts.isEmpty)
                }
            }
            .navigationDestination(for: MessageSummary.self) { ThreadView(message: $0) }
            .sheet(isPresented: $composing) { ComposeView(reply: nil) }
            .sheet(isPresented: $addingAccount) { AddAccountView() }
        }
    }

    var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Všetko", "tray.full.fill", .accentColor, selected: category == nil) { category = nil }
                ForEach(MailCategory.allCases) { c in
                    chip(c.title, c.symbol, ProjectColor.of(c.colorName), selected: category == c) { category = c }
                }
            }
            .padding(.horizontal)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
        .listRowSeparator(.hidden)
    }

    func chip(_ title: String, _ symbol: String, _ color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? AnyShapeStyle(color) : AnyShapeStyle(.quaternary), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Conversation list with pull to refresh and swipe actions.
struct MessageList: View {
    @Environment(MobileModel.self) private var model
    let messages: [MessageSummary]
    var header: AnyView? = nil

    var body: some View {
        List {
            if let header { header }
            ForEach(messages) { m in
                NavigationLink(value: m) { MessageRow(message: m) }
                    .swipeActions(edge: .leading) {
                        let unread = model.unread(m)
                        Button { Task { await model.markThread(m, seen: unread) } } label: {
                            Label(unread ? "Prečítané" : "Neprečítané", systemImage: unread ? "envelope.open" : "envelope.badge")
                        }.tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await model.trash(m) } } label: { Label("Kôš", systemImage: "trash") }
                        Button { Task { await model.archive(m) } } label: { Label("Archivovať", systemImage: "archivebox") }.tint(.indigo)
                    }
            }
            if messages.isEmpty {
                Text("Nič tu nie je.").foregroundStyle(.secondary).frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }
}

struct MessageRow: View {
    @Environment(MobileModel.self) private var model
    let message: MessageSummary

    var body: some View {
        let unread = model.unread(message)
        let count = model.count(message)
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: message.fromName, address: message.fromAddress)
                .overlay(alignment: .topLeading) {
                    if unread { Circle().fill(.blue).frame(width: 11, height: 11).overlay(Circle().stroke(.background, lineWidth: 2)).offset(x: -3, y: -2) }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.fromDisplay).font(.body.weight(unread ? .semibold : .regular)).lineLimit(1)
                    if count > 1 { Text("\(count)").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                    Spacer(minLength: 6)
                    if message.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                    Text(MailDate.short(message.date)).font(.caption).foregroundStyle(unread ? .blue : .secondary)
                }
                Text(message.subject.isEmpty ? "(bez predmetu)" : message.subject)
                    .font(.subheadline.weight(unread ? .medium : .regular)).lineLimit(1)
                Text(message.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if model.accounts.count > 1, let a = model.account(message.accountID) {
                    Text(a.email).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Projects

struct ProjectsView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if model.projects.isEmpty {
                    Text("Projekty si zatiaľ zakladáš v Courieri na Macu.").foregroundStyle(.secondary)
                }
                ForEach(model.projects) { p in
                    NavigationLink(value: p) {
                        HStack(spacing: 12) {
                            Image(systemName: p.symbol)
                                .font(.body.weight(.semibold)).foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(ProjectColor.of(p.color).gradient, in: .rect(cornerRadius: 9))
                            Text(p.name)
                            Spacer()
                            let n = model.unreadCount(p)
                            if n > 0 { Text("\(n)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Projekty")
            .navigationDestination(for: Project.self) { p in
                MessageList(messages: model.projectMessages(p)).navigationTitle(p.name)
            }
            .navigationDestination(for: MessageSummary.self) { ThreadView(message: $0) }
            .refreshable { await model.refresh() }
        }
    }
}

// MARK: Search

struct SearchView: View {
    @Environment(MobileModel.self) private var model
    /// The field itself is on RootView's TabView (see there).
    let query: String

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    ContentUnavailableView("Hľadaj v celej pošte", systemImage: "magnifyingglass",
                                           description: Text("Odosielateľ, predmet aj text správy."))
                } else {
                    MessageList(messages: model.search(query))
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Hľadať")
            .navigationDestination(for: MessageSummary.self) { ThreadView(message: $0) }
        }
    }
}
#endif
