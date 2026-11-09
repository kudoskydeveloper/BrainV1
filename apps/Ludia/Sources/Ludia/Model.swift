import SwiftUI

/// `brain ludia`: everyone worth showing, with "ozvi sa", "zabúdaš" and celebrations.
struct Overview: Codable {
    var generatedAt: String
    var settings: Settings
    var sources: [String: SourceState]
    var due: [String]
    var fading: [String]
    var celebrations: [Celebration]
    var people: [Person]

    struct Settings: Codable { var everyDays: Int; var fadingDays: Int; var sources: [String: String]; var crm: Crm? }
    /// Work CRM (optional): any read tool of an MCP server, asked with the person's e-mail. Nothing company-specific in code.
    struct Crm: Codable, Hashable { var label: String; var server: String; var tool: String; var args: String; var groups: [String] }
    struct SourceState: Codable { var ok: Bool; var error: String? }

    static func decode(_ d: Data) throws -> Overview { try JSONDecoder.snake.decode(Overview.self, from: d) }
    func encoded() throws -> Data { try JSONEncoder.snake.encode(self) }

    func person(_ id: String) -> Person? { people.first { $0.id == id } }
}

extension JSONDecoder {
    static let snake: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()
}
extension JSONEncoder {
    static let snake: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()
}

struct Person: Codable, Identifiable, Hashable {
    var id: String
    var keys: [String]
    var name: String
    var aliases: [String]
    var company: String?
    var business: String
    var businessGuessed: Bool
    var emails: [String]
    var phones: [String]
    var birthday: String?
    var birthdaySource: String?
    var last: Last?
    var channels: [Channel]
    var whatsapp: WhatsApp?
    var mail: Mail?
    var chats: [Chat]
    var meetings: [Meeting]
    var nextMeeting: NextMeeting?
    var groups: [String]
    var follow: Bool
    var every: Int
    var note: String
    var promisesOpen: Int
    var due: Bool
    var score: Double
    var celebration: CelebrationMark?
    /// Merged by hand with another record (Zlúčiť); split undoes it.
    var linked: Bool?

    struct Last: Codable, Hashable { var channel: String; var date: String; var days: Int? }
    struct Channel: Codable, Hashable { var channel: String; var date: String }
    struct WhatsApp: Codable, Hashable { var chat: String; var phone: String?; var messages: Int; var last: String? }
    struct Mail: Codable, Hashable { var sent: Int; var received: Int; var last: String?; var lastSubject: String? }
    struct Chat: Codable, Hashable { var id: String; var network: String; var last: String; var unread: Int? }
    struct Meeting: Codable, Hashable { var title: String; var date: String; var path: String?; var business: String? }
    struct NextMeeting: Codable, Hashable { var title: String; var start: String; var id: String? }
    struct CelebrationMark: Codable, Hashable { var date: String; var kind: String }

    var biz: Business { Business(rawValue: business) ?? .work }
    var days: Int? { last?.days }
    var initials: String {
        let w = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        let s = w.count >= 2 ? "\(w[0].prefix(1))\(w[w.count - 1].prefix(1))" : String(name.filter(\.isLetter).prefix(2))
        return s.isEmpty ? "?" : s.uppercased()
    }
    /// "pred 12 dňami · WhatsApp", "dnes · E-mail", "ešte nikdy".
    var lastLine: String {
        guard let l = last else { return "Zatiaľ žiadny kontakt" }
        return "\(Fmt.ago(l.days)) · \(l.channel)"
    }
    /// Phone for WhatsApp / Messages: the WhatsApp one first.
    var mainPhone: String? { whatsapp?.phone ?? phones.first }
    var isOverdue: Bool { follow && (days ?? .max) >= every }
    /// Folded words of the name, for finding look-alikes.
    var words: [String] { name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split { !$0.isLetter }.map(String.init) }
    /// Likely the same person: same surname and first names that start alike (Stanka / Stanislava), or one name has a single
    /// word that is in the other ("Bielikova" / "Alexandra Bieliková").
    func looksLike(_ o: Person) -> Bool {
        let a = words, b = o.words
        guard !a.isEmpty, !b.isEmpty, id != o.id, !name.contains("@"), !o.name.contains("@") else { return false }
        if a.count == 1 || b.count == 1 {   // "Bielikova" is "Alexandra Bieliková", but "Jakub" isn't every Jakub
            let (one, many) = a.count == 1 ? (a, b) : (b, a)
            return many.count > 1 && one[0].count > 3 && many.last == one[0]
        }
        guard a.last == b.last, a.last!.count > 2 else { return false }
        return a[0].prefix(3) == b[0].prefix(3) || a[0].prefix(1) == b[0].prefix(1)
    }
}

struct Celebration: Codable, Hashable, Identifiable {
    var date: String
    var kind: String
    var who: String
    var age: Int?
    var contacts: [Contact]
    var people: [String]
    var source: String?
    struct Contact: Codable, Hashable { var name: String?; var phone: String?; var company: String? }

    var id: String { "\(date)|\(kind)|\(who)" }
    var day: Date { Fmt.day(date) }
    var isBirthday: Bool { kind == "narodeniny" }
    var label: String { isBirthday ? (age.map { "Narodeniny (\($0))" } ?? "Narodeniny") : "Meniny" }
}

/// `brain ludia-person <id>`.
struct Detail: Codable {
    var person: Person?
    var sources: [String: Overview.SourceState]?
    var whatsapp: [Msg]?
    var chats: [ChatMessages]?
    var mails: [MailRow]?
    var tasks: [Task]?
    var notes: [Note]?
    var promises: [Promise]?
    var crm: CrmResult?
    var error: String?

    struct Msg: Codable, Hashable { var at: String?; var me: Bool; var who: String?; var text: String? }
    struct ChatMessages: Codable, Hashable { var id: String; var network: String; var messages: [Msg] }
    struct MailRow: Codable, Hashable { var id: Int; var subject: String; var from: String?; var sent: Bool; var date: String; var snippet: String?; var url: String? }
    struct Task: Codable, Hashable { var id: String; var content: String; var due: String?; var priority: String?; var account: String; var url: String? }
    struct Note: Codable, Hashable { var text: String; var topic: String? }
    struct CrmResult: Codable, Hashable { var label: String; var items: [CrmItem] }
    struct CrmItem: Codable, Hashable { var name: String; var detail: String?; var email: String? }

    static func decode(_ d: Data) throws -> Detail { try JSONDecoder.snake.decode(Detail.self, from: d) }
}

struct Promise: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    var date: String?
    var done: Bool
    var due: String?
    var doneAt: String?
}

enum Business: String, CaseIterable, Identifiable {
    case tenT = "10t", kudosky, work, personal
    var id: String { rawValue }
    var name: String {
        switch self {
        case .tenT: "10T"
        case .kudosky: "Kudosky"
        case .work: "Práca"
        case .personal: "Súkromné"
        }
    }
    var symbol: String {
        switch self {
        case .tenT: "hammer.fill"
        case .kudosky: "hand.thumbsup.fill"
        case .work: "briefcase.fill"
        case .personal: "heart.fill"
        }
    }
    var color: Color {
        switch self {
        case .tenT: .indigo
        case .kudosky: .orange
        case .work: .blue
        case .personal: .pink
        }
    }
}

/// Channel names as Brain writes them → symbol and color.
enum ChannelStyle {
    static func symbol(_ c: String) -> String {
        switch c {
        case "WhatsApp": "phone.bubble.fill"
        case "E-mail": "envelope.fill"
        case "Messenger": "message.fill"
        case "iMessage": "bubble.left.fill"
        case "Telegram": "paperplane.fill"
        case "Instagram": "camera.fill"
        case "LinkedIn": "briefcase.circle.fill"
        case "Meeting": "person.2.wave.2.fill"
        default: "bubble.left.and.bubble.right.fill"
        }
    }
    static func color(_ c: String) -> Color {
        switch c {
        case "WhatsApp": .green
        case "E-mail": .blue
        case "Messenger": .purple
        case "iMessage": .mint
        case "Telegram": .cyan
        case "Instagram": .pink
        case "LinkedIn": .indigo
        case "Meeting": .orange
        default: .secondary
        }
    }
}

/// The sources the settings show, in order, with what each one is.
enum Source: String, CaseIterable, Identifiable {
    case whatsapp, mail, meetings, contacts, Messenger, iMessage, Telegram, Instagram, LinkedIn
    var id: String { rawValue }
    var name: String {
        switch self {
        case .whatsapp: "WhatsApp"
        case .mail: "E-mail (Courier)"
        case .meetings: "Meetingy"
        case .contacts: "Kontakty, narodeniny a meniny"
        default: rawValue
        }
    }
    var detail: String {
        switch self {
        case .whatsapp: "Chaty 1:1 z WhatsAppu na Macu (aspoň 5 správ)."
        case .mail: "Ľudia, s ktorými si si písal oboma smermi."
        case .meetings: "Nahrané meetingy z Fathomu a najbližšie meetingy v kalendári."
        case .contacts: "Kontakty z iPhonu: firma, narodeniny, meniny."
        default: "Chaty 1:1 cez Beeper (skupiny nikdy)."
        }
    }
    var symbol: String { self == .contacts ? "person.crop.circle.fill" : ChannelStyle.symbol(self == .mail ? "E-mail" : self == .meetings ? "Meeting" : self == .whatsapp ? "WhatsApp" : rawValue) }
    var color: Color { self == .contacts ? .brown : ChannelStyle.color(self == .mail ? "E-mail" : self == .meetings ? "Meeting" : self == .whatsapp ? "WhatsApp" : rawValue) }
}

/// `brain ludia-crm-tools`: read tools per MCP server, for picking the work CRM.
struct CrmServer: Codable, Hashable, Identifiable {
    var server: String
    var tools: [Tool]
    struct Tool: Codable, Hashable { var name: String; var description: String }
    var id: String { server }
}

/// `brain ludia-search <topic>`: people you talked with about it, with the matching lines.
struct TopicResult: Codable {
    var query: String
    var people: [Hit]
    struct Hit: Codable, Hashable, Identifiable { var id: String; var name: String; var count: Int; var last: String?; var hits: [Line] }
    struct Line: Codable, Hashable { var channel: String; var date: String?; var text: String; var url: String? }
}

/// How the people lists are ordered (toolbar › Triedenie).
enum SortOrder: String, CaseIterable, Identifiable {
    case recent, longest, name, strength
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Posledný kontakt"
        case .longest: "Najdlhšie bez kontaktu"
        case .name: "Meno"
        case .strength: "Najsilnejší vzťah"
        }
    }
    var symbol: String {
        switch self {
        case .recent: "clock"
        case .longest: "hourglass.bottomhalf.filled"
        case .name: "textformat"
        case .strength: "chart.bar.fill"
        }
    }
    func sorted(_ list: [Person]) -> [Person] {
        switch self {
        case .recent: list.sorted { ($0.days ?? .max, -$0.score) < ($1.days ?? .max, -$1.score) }
        case .longest: list.sorted { ($0.days ?? -1, $0.score) > ($1.days ?? -1, $1.score) }
        case .name: list.sorted { $0.name.compare($1.name, locale: Fmt.sk) == .orderedAscending }
        case .strength: list.sorted { $0.score > $1.score }
        }
    }
}
