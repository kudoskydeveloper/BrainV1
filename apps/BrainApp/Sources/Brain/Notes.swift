import AppKit
import SwiftUI

/// Something Brain knows: one Markdown file with frontmatter in ~/Developer/brain/notes (written by the Brain MCP).
struct Note: Identifiable, Hashable {
    let id: String
    let file: URL
    var topic: String
    var text: String
    var date: String
    var source: String
    var path: String?
}

@MainActor
final class NotesStore: ObservableObject {
    static let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Developer/brain/notes")
    @Published var items: [Note] = []

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        items = files.filter { $0.pathExtension == "md" }.compactMap(Self.parse).sorted { $0.date > $1.date }
    }

    static func split(_ raw: String) -> (meta: [(String, String)], body: String) {
        var meta: [(String, String)] = [], body = raw
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex) {
            for line in raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                if let c = line.firstIndex(of: ":") {
                    meta.append((String(line[..<c]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)))
                }
            }
            body = String(raw[end.upperBound...])
        }
        return (meta, body)
    }

    static func parse(_ url: URL) -> Note? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (pairs, body) = split(raw)
        let meta = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        return Note(id: meta["id"] ?? url.lastPathComponent, file: url, topic: meta["topic"] ?? "", text: body.trimmingCharacters(in: .whitespacesAndNewlines),
                    date: meta["date"] ?? "", source: meta["source"] ?? "", path: meta["path"])
    }

    /// Edit in place: same file, same frontmatter (id, source, path), new topic and text, today's date.
    func save(_ n: Note, topic: String, text: String) {
        guard let raw = try? String(contentsOf: n.file, encoding: .utf8) else { return }
        var meta = Self.split(raw).meta.filter { $0.0 != "topic" && $0.0 != "date" }
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        meta.insert(("date", today), at: min(1, meta.count))
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if !t.isEmpty { meta.insert(("topic", t), at: min(2, meta.count)) }
        let head = meta.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        try? "---\n\(head)\n---\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n".write(to: n.file, atomically: true, encoding: .utf8)
        reload()
    }

    /// Forget = move the note file to the Trash, so it can be put back.
    func trash(_ n: Note) {
        try? FileManager.default.trashItem(at: n.file, resultingItemURL: nil)
        reload()
    }
}

/// "What Brain knows": facts grouped as knowledge (where things are, then everything else by topic), searchable and editable.
struct KnowledgeView: View {
    @ObservedObject var store: NotesStore
    let filter: String

    var shown: [Note] {
        let f = filter.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard !f.isEmpty else { return store.items }
        return store.items.filter { "\($0.topic) \($0.text) \($0.path ?? "")".lowercased().folding(options: .diacriticInsensitive, locale: nil).contains(f) }
    }

    var body: some View {
        if store.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("Brain zatiaľ nič nevie").font(.headline)
                Text("Povedz mu niečo, napr. „zapamätaj si, že Klient Mesto je klient 10T“.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if shown.isEmpty {
            Text("Nič nezodpovedá „\(filter)“").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
        } else {
            let places = shown.filter { $0.path != nil }
            let facts = shown.filter { $0.path == nil }.sorted { $0.topic.localizedCaseInsensitiveCompare($1.topic) == .orderedAscending }
            VStack(alignment: .leading, spacing: 18) {
                if !facts.isEmpty { section("Fakty", "lightbulb", facts) }
                if !places.isEmpty { section("Kde čo je", "mappin.and.ellipse", places) }
            }
        }
    }

    func section(_ title: String, _ icon: String, _ notes: [Note]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(title) · \(notes.count)", systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(notes) { NoteCard(note: $0, store: store) }
        }
    }
}

struct NoteCard: View {
    let note: Note
    let store: NotesStore
    @State var hover = false
    @State var editing = false
    @State var topic = ""
    @State var text = ""

    var body: some View {
        Group { if editing { editor } else { card } }
            .padding(12)
            .background(.quaternary.opacity(hover || editing ? 0.55 : 0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }

    var card: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !note.topic.isEmpty { Text(note.topic).font(.system(size: 13, weight: .semibold)) }
                Text(note.text).font(.system(size: 14)).foregroundStyle(note.topic.isEmpty ? .primary : .secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(note.date)
                    if let p = note.path { Text("·"); Text(p).lineLimit(1).truncationMode(.middle) }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if let p = note.path {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (p as NSString).expandingTildeInPath)]) } label: { Image(systemName: "folder") }
                        .help("Ukázať vo Finderi")
                }
                Button { topic = note.topic; text = note.text; editing = true } label: { Image(systemName: "pencil") }.help("Upraviť")
                Button { store.trash(note) } label: { Image(systemName: "trash") }.help("Zabudnúť (presunie do Koša)")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .opacity(hover ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { topic = note.topic; text = note.text; editing = true }
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Téma", text: $topic).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 14)).scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 160)
                .padding(6).background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Zrušiť") { editing = false }.keyboardShortcut(.cancelAction)
                Button("Uložiť") { store.save(note, topic: topic, text: text); editing = false }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).tint(.brainAccent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }
}
