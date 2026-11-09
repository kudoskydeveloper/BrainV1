import Foundation
import SwiftUI

/// What `brain meetings` returns (brain/src/meetings.js).
struct MeetingsData: Codable {
    struct Source: Codable { let ok: Bool; let error: String? }
    let generatedAt: String
    let days: Double
    let sources: [String: Source]
    let upcoming: [Upcoming]
    var recordings: [Recording]

    static func decode(_ data: Data) throws -> MeetingsData {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(MeetingsData.self, from: data)
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return try e.encode(self)
    }

    func recordings(_ b: Business?) -> [Recording] { b.map { b in recordings.filter { $0.kind == b } } ?? recordings }
}

struct Person: Codable, Hashable {
    let name: String?
    let email: String?
    /// The name if there is one, else the address's local part made readable ("novak@firma.sk" → "Pazicky").
    var display: String {
        if let n = name, !n.isEmpty { return n }
        guard let e = email else { return "?" }
        return e.split(separator: "@").first.map { $0.split(separator: ".").map { $0.capitalized }.joined(separator: " ") } ?? e
    }
    var company: String? { email.flatMap { $0.split(separator: "@").last.map(String.init) } }
    var initials: String {
        let parts = display.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

struct Upcoming: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let start: String
    let end: String
    let calendar: String?
    let account: String?
    let location: String?
    let joinUrl: String?
    let people: [Person]

    var startDate: Date { Fmt.dateTime(start) }
    var endDate: Date { Fmt.dateTime(end) }
    var minutes: Double { endDate.timeIntervalSince(startDate) / 60 }
    var join: URL? { joinUrl.flatMap(URL.init(string:)) }
    var isNow: Bool { startDate <= .now && endDate > .now }
    static func == (a: Upcoming, b: Upcoming) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct NoteItem: Codable, Hashable {
    let heading: String?
    let text: String?
    let depth: Double?
    let done: Bool?
    let para: Bool?
}

struct NoteSection: Codable, Hashable, Identifiable {
    let title: String
    let kind: String
    let items: [NoteItem]
    var id: String { title }
}

enum Business: String, CaseIterable, Identifiable {
    case tenT = "10t", kudosky, personal, other
    var id: String { rawValue }
    var name: String {
        switch self {
        case .tenT: "10T Studios"
        case .kudosky: "Kudosky"
        case .personal: "Súkromné"
        case .other: "Ostatné"
        }
    }
    var color: Color {
        switch self {
        case .tenT: .blue
        case .kudosky: .purple
        case .personal: .green
        case .other: .gray
        }
    }
    var symbol: String {
        switch self {
        case .tenT: "building.2.fill"
        case .kudosky: "heart.fill"
        case .personal: "person.fill"
        case .other: "tray.fill"
        }
    }
}

struct Recording: Codable, Identifiable, Hashable {
    let date: String
    let title: String
    let folder: String
    var path: String
    var business: String
    let when: String?
    let minutes: Double?
    let people: [Person]
    let fathom: String?
    let recordedOn: String?
    let sections: [NoteSection]
    let transcriptLines: Double?
    let error: String?

    var id: String { path }
    var kind: Business { Business(rawValue: business) ?? .other }
    var day: Date { Fmt.dateTime(when ?? date) }
    var hasTime: Bool { (when ?? "").count > 10 }
    func section(_ kind: String) -> NoteSection? { sections.first { $0.kind == kind } }
    /// One line about what the meeting was for: its purpose, else the first takeaway.
    var gist: String? {
        let s = section("purpose") ?? section("takeaways")
        return s?.items.first { $0.text != nil }?.text.map(Fmt.plain)
    }
    var actionItems: [NoteItem] { section("action_items")?.items.filter { $0.text != nil } ?? [] }
    static func == (a: Recording, b: Recording) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }
}

/// What `brain meeting-prep <id>` returns.
struct Prep: Codable {
    struct Meeting: Codable { let title: String; let start: String; let end: String?; let agenda: String? }
    struct Row: Codable, Hashable {
        let title: String
        let detail: String?
        let date: String?
        let path: String?
        let client: String?
        let id: String?
        /// Courier mail opens in Courier; a note file opens in its app.
        var url: URL? {
            if client == "courier", let id { return URL(string: "courier://message/\(id)") }
            if let path { return URL(fileURLWithPath: path) }
            return nil
        }
    }
    struct CRM: Codable, Hashable { let name: String?; let account: String? }
    struct PrepPerson: Codable, Hashable {
        let name: String
        let email: String?
        let company: String?
        let crm: [CRM]
        let emails: [Row]
        let whatsapp: [Row]
    }
    let meeting: Meeting
    let companies: [String]
    let people: [PrepPerson]
    let earlier: [Row]
    let notes: [Row]
    let emails: [Row]
    let tasks: [Row]

    static func decode(_ data: Data) throws -> Prep {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Prep.self, from: data)
    }

    /// The agenda without Calendly / Meet boilerplate.
    var agenda: String? {
        guard let a = meeting.agenda else { return nil }
        let drop = ["Need to make changes", "Cancel:", "Reschedule:", "Powered by Calendly", "Join with Google Meet", "Or dial:", "More phone numbers",
                    "Learn more about Meet", "This is a Google Meet", "You can join this meeting", "Event Name", "Location:"]
        let lines = a.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { l in !drop.contains { l.contains($0) } && !l.hasPrefix("https://calendly.com") }
        let text = lines.joined(separator: "\n").replacingOccurrences(of: "\n\\s*\n", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
