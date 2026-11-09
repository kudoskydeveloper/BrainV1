import BrainCore
import SwiftUI

/// One saved conversation: what was said, and the Claude Code session that holds its full context for follow-ups.
struct Chat: Codable, Identifiable, Equatable {
    struct Line: Codable, Equatable { var mine: Bool; var text: String; var images: [String]? = nil }
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var sessionId: String?
    /// The morning brief the conversation started from, if any.
    var context: String?
    var messages: [Line]
}

/// Conversations as JSON files in ~/Library/Application Support/Brain/chats, newest first.
@MainActor
final class HistoryStore: ObservableObject {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Brain/chats")
    static let shared = HistoryStore()
    @Published var chats: [Chat] = []

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        chats = files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Chat.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    func save(_ c: Chat) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? Self.encoder.encode(c).write(to: file(c.id), options: .atomic)
        chats.removeAll { $0.id == c.id }
        chats.insert(c, at: chats.firstIndex { $0.updated <= c.updated } ?? chats.endIndex)
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var c = chats.first(where: { $0.id == id }) else { return }
        c.title = t
        try? Self.encoder.encode(c).write(to: file(id), options: .atomic)
        if let i = chats.firstIndex(where: { $0.id == id }) { chats[i] = c }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        chats.removeAll { $0.id == id }
    }

    func file(_ id: UUID) -> URL { Self.dir.appendingPathComponent("\(id.uuidString).json") }

    /// Claude Code keeps a session's transcript per working folder; without it --resume can't continue (cleaned up after ~30 days).
    static func sessionExists(_ id: String) -> Bool {
        let folder = Runner.brainDir.path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return FileManager.default.fileExists(atPath: Runner.home.appendingPathComponent(".claude/projects/\(folder)/\(id).jsonl").path)
    }

    /// A short title from the first question.
    static func title(from q: String) -> String {
        let one = q.split(whereSeparator: \.isNewline).first.map(String.init) ?? q
        return one.count > 60 ? String(one.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : one
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
