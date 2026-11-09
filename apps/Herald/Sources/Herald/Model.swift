import Foundation
import SwiftUI

/// `GET /api/state` of the linkedin-mcp server: everything the window shows, in one answer.
struct AppState: Decodable {
    var extensionConnected: Bool?
    var syncedAt: String?
    var conversationsSyncedAt: String?
    var sentInvitesSyncedAt: String?
    var connections: [Connection]
    var tags: [String: Int]
    var projects: [Project]
    var stages: [Stage]
    var countries: [String]
    var prospects: [Prospect]
    var inviteBudget: InviteBudget
    var sentInvites: [SentInvite]
    var conversations: [Conversation]
    /// Vybavené: person id (or chat id) → time of the newest message dealt with without a reply.
    var inboxDone: [String: Double]?

    static func decode(_ d: Data) throws -> AppState {
        var s = try JSONDecoder().decode(AppState.self, from: d)
        s.index()
        return s
    }

    // lookups, filled after decoding
    private(set) var byId: [String: Connection] = [:]
    private(set) var conversationByPerson: [String: Conversation] = [:]

    mutating func index() {
        byId = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var c: [String: Conversation] = [:]
        for x in conversations where x.group != true {
            guard let id = x.connectionId else { continue }
            if let old = c[id], old.daysSinceLast <= x.daysSinceLast { continue }
            c[id] = x
        }
        conversationByPerson = c
    }

    /// The live LinkedIn inbox from Beeper (`brain linkedin-inbox`) over the history the linkedin server downloaded earlier:
    /// a person's Beeper chat replaces their older conversation, and their last message moves if Beeper's is newer.
    mutating func merge(_ inbox: BeeperInbox) {
        var people = Set<String>()
        var fresh: [Conversation] = []
        for c in inbox.chats {
            let at = Date(timeIntervalSince1970: c.at / 1000)
            let id = c.profileID.flatMap { byId[$0] != nil ? $0 : nil }
            if let id { people.insert(id) }
            fresh.append(Conversation(id: c.chatID, with: c.name, connectionId: id, headline: id.flatMap { byId[$0]?.headline }, group: false,
                                      unread: c.unread, lastFrom: c.from, lastAt: at.formatted(.iso8601.year().month().day()),
                                      daysSinceLast: Fmt.daysAgo(at), lastText: c.text, url: nil, beeper: true, lastAtMs: c.at))
            if let id, let i = connections.firstIndex(where: { $0.id == id }), (connections[i].lastMessageAt ?? 0) <= c.at {
                connections[i].lastMessageAt = c.at
                connections[i].lastFrom = c.from
            }
        }
        conversations = fresh + conversations.filter { $0.connectionId.map { !people.contains($0) } ?? true }
        conversations.sort { $0.daysSinceLast < $1.daysSinceLast }
        beeperSyncedAt = inbox.syncedAt
        index()
    }
    var beeperSyncedAt: String? = nil

    /// Čaká na teba: they wrote last, and it isn't closed. Closed means the person is Nekontaktovať (private chats), every
    /// project they're in is at stage "no" (a refusal is closed on purpose, never guessed from the text), or the last
    /// message is only a 👍 or a short thanks.
    func needsReply(_ c: Conversation) -> Bool {
        guard c.theyWroteLast, !isDone(c) else { return false }
        if let id = c.connectionId, let p = byId[id] {
            if p.doNotContact { return false }
            let stages = p.projects.values.map(\.stage)
            if !stages.isEmpty, stages.allSatisfy({ $0 == "no" }) { return false }
        }
        return !Self.isAcknowledgement(c.lastText)
    }

    /// Marked Vybavené, and nothing newer came since.
    func isDone(_ c: Conversation) -> Bool {
        guard let at = inboxDone?[c.doneKey] else { return false }
        return at >= (c.lastAtMs ?? 0)
    }

    /// Only an emoji, a reaction, "ok" or a short thanks: the conversation is done, no answer needed.
    static func isAcknowledgement(_ text: String?) -> Bool {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty || t == "[reaction]" { return true }
        if t.contains("?") || t.count > 20 { return false }
        let words = ["ok", "okej", "dik", "díky", "děkuji", "dakujem", "ďakujem", "vdaka", "vďaka", "thanks", "thx", "super", "rozumiem"]
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.isEmpty || words.contains { t.hasPrefix($0) }
    }

    func project(_ id: String) -> Project? { projects.first { $0.id == id } }
    func stage(_ key: String) -> Stage? { stages.first { $0.key == key } }

    enum CodingKeys: String, CodingKey {
        case extensionConnected, syncedAt, conversationsSyncedAt, sentInvitesSyncedAt, connections, tags, projects, stages, countries,
             prospects, inviteBudget, sentInvites, conversations, inboxDone
    }
}

struct Membership: Codable, Hashable {
    var stage: String
    var at: String?
    var from: String?
}

struct Connection: Decodable, Identifiable, Hashable {
    let id: String
    var firstName: String
    var lastName: String
    var headline: String
    var connectedAt: Double?
    var publicIdentifier: String?
    var tags: [String]
    var note: String
    var projects: [String: Membership]
    var seniority: String?
    var role: String?
    var country: String?
    var location: String?
    var lastMessageAt: Double?
    var lastFrom: String?

    var name: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }
    var url: URL? { publicIdentifier.flatMap { URL(string: "https://www.linkedin.com/in/\($0)/") } }
    var connected: Date? { connectedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var lastTalk: Date? { lastMessageAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var daysSinceTalk: Int? { lastTalk.map { max(0, Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0) } }
    var doNotContact: Bool { tags.contains("do-not-contact") }
    /// Tags that aren't stages of a project (those show as stages).
    func plainTags(_ projects: [Project]) -> [String] {
        tags.filter { t in t != "do-not-contact" && !projects.contains { t.hasPrefix($0.id + "-") } }
    }
}

struct Project: Decodable, Identifiable, Hashable {
    let id: String
    var name: String
    var playbook: String
    var color: String?
    var archived: Bool?
    var people: Int
    var prospects: Int
    var stages: [String: Int]

    var tint: Color { Project.palette[color ?? ""] ?? Avatar.color(for: id) }
    static let palette: [String: Color] = ["blue": .blue, "purple": .purple, "pink": .pink, "orange": .orange, "green": .green,
                                           "teal": .teal, "indigo": .indigo, "red": .red, "mint": .mint]
}

struct Stage: Decodable, Identifiable, Hashable {
    let key: String
    var label: String
    var rank: Int
    var id: String { key }

    var symbol: String {
        switch key {
        case "lead": "scope"
        case "outreach": "paperplane.fill"
        case "followed-up": "arrow.uturn.forward"
        case "later": "clock.fill"
        case "no": "xmark.circle.fill"
        case "meeting": "calendar.badge.checkmark"
        default: "circle"
        }
    }
    var tint: Color {
        switch key {
        case "lead": .gray
        case "outreach": .blue
        case "followed-up": .indigo
        case "later": .orange
        case "no": .red
        case "meeting": .green
        default: .secondary
        }
    }
}

struct Prospect: Decodable, Identifiable, Hashable {
    let slug: String
    var name: String
    var headline: String?
    var location: String?
    var degree: String?
    var mutual: String?
    var canConnect: Bool?
    var pending: Bool?
    var foundAt: String?
    var invitedAt: String?
    var projects: [String: Membership]?
    var query: Query?
    var id: String { slug }
    var url: URL? { URL(string: "https://www.linkedin.com/in/\(slug)/") }

    struct Query: Decodable, Hashable { var keywords: String?; var country: String?; var degree: String?; var project: String? }
}

/// `brain linkedin-inbox`: one-to-one LinkedIn chats in Beeper with their newest message.
struct BeeperInbox: Codable {
    var syncedAt: String
    var chats: [Chat]
    struct Chat: Codable {
        var chatID: String
        var profileID: String?
        var name: String
        var unread: Int
        var at: Double
        var from: String?
        var text: String
    }
}

struct InviteBudget: Decodable, Hashable {
    var today: Int
    var week: Int
    var dailyCap: Int
    var weeklyCap: Int
    var left: Int { max(0, min(dailyCap - today, weeklyCap - week)) }
}

struct SentInvite: Decodable, Identifiable, Hashable {
    let id: String
    var name: String
    var headline: String?
    var slug: String?
    var sent: String
    var daysAgo: Int
    var note: String?
    var url: URL? { slug.flatMap { URL(string: "https://www.linkedin.com/in/\($0)/") } }
}

struct Conversation: Decodable, Identifiable, Hashable {
    let id: String
    var with: String
    var connectionId: String?
    var headline: String?
    var group: Bool?
    var unread: Int?
    var lastFrom: String?
    var lastAt: String
    var daysSinceLast: Int
    var lastText: String?
    var url: String?
    /// From Beeper (live), not from the old browser download.
    var beeper: Bool? = nil
    var lastAtMs: Double? = nil
    /// Vybavené is kept per person (their chat may change), else per chat.
    var doneKey: String { connectionId ?? id }

    /// They wrote last, within a month (older ones are dead threads, not a to-do). Whether it waits for you is
    /// `AppState.needsReply`, which also knows the person.
    var theyWroteLast: Bool { group != true && lastFrom == "them" && daysSinceLast <= 30 }
    /// You wrote last, 3+ days ago, within two months.
    var waiting: Bool { group != true && lastFrom == "me" && (3...60).contains(daysSinceLast) }
}

/// What the sidebar can show.
enum Folder: Hashable {
    case project(String)
    case all, talked, never, doNotContact
    case reply, waiting, conversations
    case prospects, invited, pending

    init?(_ s: String) {
        switch s {
        case "all": self = .all
        case "talked": self = .talked
        case "never": self = .never
        case "reply", "inbox": self = .reply
        case "waiting": self = .waiting
        case "conversations": self = .conversations
        case "prospects": self = .prospects
        case "invited": self = .invited
        case "pending": self = .pending
        default:
            if s.hasPrefix("project/") { self = .project(String(s.dropFirst(8))) } else { return nil }
        }
    }

    var isPeople: Bool {
        switch self {
        case .project, .all, .talked, .never, .doNotContact: true
        default: false
        }
    }
}
