import AppKit
import CourierCore
import SwiftUI

// MARK: Model

extension AppModel {
    enum ContactSort: String, CaseIterable { case frequent, name, recent
        var title: String { switch self { case .frequent: "Najčastejšie"; case .name: "Podľa mena"; case .recent: "Naposledy" } }
    }

    /// Everyone from the mail, refreshed in the background each time the tab opens (the old list stays meanwhile).
    func loadMailContacts() {
        guard !contactsLoading else { return }
        contactsLoading = true
        let store = store
        let mine = Set(accounts.map { $0.email.lowercased() })
        Task.detached(priority: .userInitiated) {
            let list = store.allContacts(myAddresses: mine)
            let sorted = list.sorted { $0.id < $1.id }
            await MainActor.run {
                if sorted != self.mailContacts { self.mailContacts = sorted }
                self.contactsLoading = false
            }
        }
    }

    func filteredContacts(_ sort: ContactSort, query: String) -> [MailContact] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        let list = q.isEmpty ? mailContacts : mailContacts.filter { c in
            let name = Self.fold(c.name)
            // every typed word has to match the name or the address
            return q.split(separator: " ").allSatisfy { w in name.contains(w) || c.address.lowercased().contains(w) }
        }
        switch sort {
        case .frequent: return list.sorted { $0.total != $1.total ? $0.total > $1.total : $0.address < $1.address }
        case .recent: return list.sorted { $0.lastDate > $1.lastDate }
        case .name:
            return list.map { (Self.fold($0.display), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func fold(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil) }

    /// Puts text on the clipboard and shows a short "Skopírované" toast.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedText = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if self.copiedText == text { self.copiedText = nil }
        }
    }

    func newDraft(to address: String) -> UUID {
        let id = newDraft()
        drafts[id]?.to = address
        return id
    }
}

// MARK: Views

/// The Adresár list: everyone who ever wrote or was written to.
struct AddressBookView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @AppStorage("contacts.sort") private var sort: AppModel.ContactSort = .frequent
    /// Filtered and sorted once per change of the query, sort or data, not on every redraw (selection, hover…).
    @State private var list: [MailContact] = []

    var body: some View {
        List(selection: $model.selectedContact) {
            ForEach(list) { c in
                ContactRow(c: c).tag(c.id).softSelection(model.selectedContact == c.id).contextMenu { ContactMenu(c: c) }
            }
        }
        .listStyle(.inset)
        .background(NoTableHighlight())
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
            if let id = ids.first { model.copy(model.mailContacts.first { $0.id == id }?.address ?? id) }
        }
        .overlay {
            if list.isEmpty {
                if model.contactsLoading { ProgressView("Načítavam kontakty…") }
                else {
                    ContentUnavailableView(model.search.isEmpty ? "Žiadne kontakty" : "Nič sa nenašlo", systemImage: "person.crop.rectangle.stack",
                                           description: Text("Hľadaj podľa mena alebo e-mailu."))
                }
            }
        }
        .navigationTitle("Adresár")
        .navigationSubtitle("\(list.count)")
        .toolbar {
            ToolbarItemGroup {
                Picker("Zoradiť", selection: $sort) {
                    ForEach(AppModel.ContactSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
                .help("Zoradiť kontakty")
                Button { openWindow(id: "compose", value: model.newDraft()) } label: { Label("Nová správa", systemImage: "square.and.pencil") }
            }
        }
        .onAppear { refilter(); model.loadMailContacts() }
        .onChange(of: model.mailContacts) { refilter() }
        .onChange(of: sort) { refilter() }
        .task(id: model.search) {
            // typing: wait a moment so every keystroke doesn't refilter
            if !model.search.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            refilter()
        }
    }

    func refilter() { list = model.filteredContacts(sort, query: model.search) }
}

/// One contact row: plain texts only (no per-row hover state), so long lists scroll smoothly.
struct ContactRow: View, Equatable {
    let c: MailContact
    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: c.name, address: c.address, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.display).font(.headline.weight(.medium)).lineLimit(1)
                if !c.name.isEmpty { Text(c.address).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Text("\(c.total)×").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
    }
}

struct ContactMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    let c: MailContact
    var body: some View {
        Button("Kopírovať e-mail") { model.copy(c.address) }
        if !c.name.isEmpty { Button("Kopírovať meno a e-mail") { model.copy("\(c.name) <\(c.address)>") } }
        Divider()
        Button("Nová správa") { openWindow(id: "compose", value: model.newDraft(to: c.name.isEmpty ? c.address : "\(c.name) <\(c.address)>")) }
    }
}

/// The selected contact: who it is, then the mail with them.
struct ContactDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @State private var mail: [MessageSummary] = []

    var contact: MailContact? { model.mailContacts.first { $0.id == model.selectedContact } }

    var body: some View {
        if let c = contact {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16) {
                        Avatar(name: c.name, address: c.address, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.display).font(.title2.weight(.bold)).textSelection(.enabled)
                            CopyableAddress(address: c.address, font: .title3)
                            Text("Od neho \(c.fromCount)  ·  Pre neho \(c.toCount)  ·  naposledy \(c.lastDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button { openWindow(id: "compose", value: model.newDraft(to: c.name.isEmpty ? c.address : "\(c.name) <\(c.address)>")) } label: {
                            Label("Nová správa", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.glassProminent)
                        Button { model.copy(c.address) } label: { Label("Kopírovať e-mail", systemImage: "doc.on.doc") }
                        if !c.name.isEmpty {
                            Button { model.copy("\(c.name) <\(c.address)>") } label: { Label("Meno a e-mail", systemImage: "person.text.rectangle") }
                        }
                    }
                    .padding(.top, 14)

                    Text("Pošta").font(.headline).padding(.top, 24).padding(.bottom, 6)
                    if mail.isEmpty { Text("Žiadne správy").foregroundStyle(.secondary) }
                    ForEach(mail) { m in
                        Button { model.show(m) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: m.fromAddress.lowercased() == c.id ? "arrow.down.left" : "arrow.up.right")
                                    .font(.caption).foregroundStyle(.tertiary).frame(width: 14)
                                Text(m.subject.isEmpty ? "(bez predmetu)" : m.subject).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(m.date.listLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
            .navigationTitle("")
            .task(id: c.id) {
                let store = model.store, addr = c.address
                mail = await Task.detached { store.messages(involving: addr, limit: 200) }.value
            }
        } else {
            ContentUnavailableView("Adresár", systemImage: "person.crop.rectangle.stack",
                                   description: Text("Vyber kontakt. Kliknutím na e-mail ho skopíruješ."))
        }
    }
}

/// An e-mail address that copies itself on click.
struct CopyableAddress: View {
    @EnvironmentObject var model: AppModel
    let address: String
    var font: Font = .caption
    @State private var hover = false

    var body: some View {
        Text(address)
            .font(font)
            .foregroundStyle(hover ? Color.accentColor : .secondary)
            .underline(hover)
            .lineLimit(1)
            .onHover { hover = $0; if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .onTapGesture { model.copy(address) }
            .help("Kliknutím skopíruješ \(address)")
    }
}

struct CopiedToast: View {
    let text: String
    var body: some View {
        Label("Skopírované: \(text)", systemImage: "doc.on.doc.fill")
            .font(.callout.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .allowsHitTesting(false)
    }
}

/// Recipient line where every name is a link that copies its address.
enum AddressLinks {
    static let scheme = "courier-copy"

    static func line(_ parts: [(label: String, addresses: [EmailAddress])]) -> AttributedString {
        var out = AttributedString()
        for (i, p) in parts.enumerated() where !p.addresses.isEmpty {
            if i > 0 && !out.characters.isEmpty { out += AttributedString("  ·  ") }
            out += AttributedString(p.label + ": ")
            for (j, a) in p.addresses.enumerated() {
                if j > 0 { out += AttributedString(", ") }
                var s = AttributedString(a.display)
                s.link = url(a.address)
                out += s
            }
        }
        return out
    }

    static func url(_ address: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.path = address
        return c.url
    }

    /// Handles clicks on those links: copy instead of opening anything.
    @MainActor static func handler(_ model: AppModel) -> OpenURLAction {
        OpenURLAction { url in
            guard url.scheme == scheme else { return .systemAction }
            model.copy(url.path.removingPercentEncoding ?? url.path)
            return .handled
        }
    }
}

// MARK: Lighter list selection

/// Turns off the system's grey/blue selection fill of the List it sits in, so rows can draw a softer one themselves.
struct NoTableHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) { (v as? Probe)?.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { self.apply() } }
        func apply() {
            guard window != nil else { return }
            // the probe sits behind the list: take the table under the probe's center (never the sidebar's)
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var v: NSView? = superview
            while let cur = v {
                if let t = Self.table(in: cur, at: center) { if t.selectionHighlightStyle != .none { t.selectionHighlightStyle = .none }; return }
                v = cur.superview
            }
        }
        static func table(in v: NSView, at p: NSPoint, depth: Int = 0) -> NSTableView? {
            if let t = v as? NSTableView {
                let frame = (t.enclosingScrollView ?? t).convert((t.enclosingScrollView ?? t).bounds, to: nil)
                return frame.contains(p) ? t : nil
            }
            guard depth < 12 else { return nil }
            for s in v.subviews { if let t = table(in: s, at: p, depth: depth + 1) { return t } }
            return nil
        }
    }
}

extension View {
    /// Soft tinted background for a selected list row (pair with `NoTableHighlight` on the list).
    func softSelection(_ on: Bool) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.13) : .clear)
                .padding(.horizontal, 6)
        )
    }
}
