import CourierCore
import Foundation

// courier-mcp: a stdio MCP server (JSON-RPC, one message per line) over Courier's local cache.
// Reading comes straight from SQLite, so it works while the app is closed; anything that needs the network
// (downloading a body, syncing) goes to the running app over its control socket, launching it in the background if needed.

setvbuf(stdout, nil, _IOLBF, 0)
let store: Store
do { store = try Store() } catch {
    FileHandle.standardError.write(Data("courier-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}

let iso = ISO8601DateFormatter()

// MARK: App control socket

func askApp(_ request: [String: Any], launch: Bool = true) -> [String: Any] {
    func once() -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Store.socketPath
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        var out = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while !data.contains(0x0A) {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return (try? JSONSerialization.jsonObject(with: data.prefix { $0 != 0x0A })) as? [String: Any]
    }
    if let r = once() { return r }
    guard launch else { return ["ok": false, "error": "Courier nebeží"] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", "com.lockedin.courier"]
    try? p.run()
    p.waitUntilExit()
    for _ in 0..<40 {
        usleep(500_000)
        if let r = once() { return r }
    }
    return ["ok": false, "error": "Courier sa nepodarilo spustiť"]
}

// MARK: Tools

var tickets: [String: Ticket] = [:]
let accountsByID = { Dictionary(uniqueKeysWithValues: store.accounts().map { ($0.id, $0) }) }

func messageJSON(_ m: MessageSummary, _ accounts: [String: Account]) -> [String: Any] {
    var d: [String: Any] = [
        "id": m.id, "account": accounts[m.accountID]?.email ?? m.accountID, "folder": ModifiedUTF7.decode(m.folder),
        "from": m.fromName.isEmpty ? m.fromAddress : "\(m.fromName) <\(m.fromAddress)>", "subject": m.subject,
        "date": iso.string(from: m.date), "unread": !m.seen,
    ]
    if m.flagged { d["flagged"] = true }
    if m.hasAttachments { d["attachments"] = true }
    if !m.snippet.isEmpty { d["snippet"] = m.snippet }
    d["thread_id"] = m.threadID
    d["group"] = m.category.rawValue
    if let t = tickets[m.threadKey] {
        if let s = t.status { d["status"] = s.rawValue }
        if !t.tags.isEmpty { d["tags"] = t.tags }
    }
    return d
}

func resolveAccount(_ v: Any?) -> Account? {
    guard let s = (v as? String)?.lowercased(), !s.isEmpty else { return nil }
    return store.accounts().first { $0.id.lowercased() == s || $0.email.lowercased() == s }
}

func resolveFolder(_ account: Account, _ v: Any?) -> Folder? {
    let folders = store.folders(account: account.id)
    guard let s = (v as? String)?.lowercased(), !s.isEmpty else { return folders.first { $0.role == .inbox } }
    return folders.first { $0.path.lowercased() == s || ModifiedUTF7.decode($0.path).lowercased() == s || $0.role.rawValue == s
        || $0.displayName.lowercased() == s || $0.name.lowercased() == s }
}

func resolveProject(_ v: Any?) -> Project? {
    guard let s = (v as? String)?.lowercased(), !s.isEmpty else { return nil }
    return store.projects().first { $0.id.lowercased() == s || $0.name.lowercased() == s }
}

struct ToolError: Error { let message: String }

let sendSchema: [String: Any] = ["type": "object", "properties": [
    "account": ["type": "string"], "to": ["type": "string"], "cc": ["type": "string"], "bcc": ["type": "string"],
    "subject": ["type": "string"], "body": ["type": "string"], "reply_to": ["type": "integer"],
    "attachments": ["type": "array", "items": ["type": "string"]], "signature": ["type": "string"],
    "draft_id": ["type": "integer", "description": "id konceptu (z draft alebo list_messages folder drafts), ktorý sa odosiela: po odoslaní zmizne z Konceptov. Bez body sa pošle text konceptu tak, ako je."],
    "send_at": ["type": "string", "description": "naplánovať odoslanie: YYYY-MM-DDTHH:mm (miestny čas); správa čaká v Courieri v Na odoslanie"]]]
let unsubscribeSchema: [String: Any] = ["type": "object", "properties": [
    "id": ["type": "integer", "description": "id správy od odosielateľa"],
    "ids": ["type": "array", "items": ["type": "integer"]],
    "sender": ["type": "string", "description": "e-mailová adresa odosielateľa"],
    "archive": ["type": "boolean", "description": "archivovať jeho správy z Doručenej pošty (predvolene true)"]]]
let deleteSchema: [String: Any] = ["type": "object", "properties": ["id": ["type": "integer"], "ids": ["type": "array", "items": ["type": "integer"]],
                                                                   "permanent": ["type": "boolean"]]]
let moveSchema: [String: Any] = ["type": "object", "properties": ["id": ["type": "integer"], "ids": ["type": "array", "items": ["type": "integer"]],
                                                                 "folder": ["type": "string"]], "required": ["folder"]]
/// Tools that only read get readOnlyHint, so Brain runs them without asking.
let readOnly: Set<String> = ["outbox", "tickets", "tags", "accounts", "folders", "projects", "list_messages", "search", "read_message", "thread", "attachments", "groups", "signatures"]

let toolDefs: [[String: Any]] = [
    ["name": "accounts", "description": "E-mailové účty v Courieri (id, e-mail, meno) s počtom neprečítaných v doručenej pošte.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "folders", "description": "Priečinky účtu (doručené, koncepty, odoslané, spam, kôš, vlastné) s počtom neprečítaných a správ.",
     "inputSchema": ["type": "object", "properties": ["account": ["type": "string", "description": "e-mail alebo id účtu"]], "required": ["account"]]],
    ["name": "projects", "description": "Projekty z nástenky Courieru: ktoré schránky, priečinky a odosielatelia k nim patria a koľko majú neprečítaných.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "list_messages",
     "description": "Zoznam konverzácií (jedna položka na vlákno, jej najnovšia správa; najnovšie prvé). Bez parametrov: doručená pošta všetkých účtov. S project: správy projektu. S account (+ folder): priečinok účtu (folder môže byť názov alebo rola: inbox, sent, drafts, junk, trash).",
     "inputSchema": ["type": "object", "properties": [
        "account": ["type": "string"], "folder": ["type": "string"], "project": ["type": "string", "description": "názov alebo id projektu"],
        "status": ["type": "string", "enum": ["open", "waiting", "done"], "description": "tikety v danom stave"], "tag": ["type": "string"],
        "group": ["type": "string", "enum": ["people", "notifications", "newsletters", "invites", "invoices"],
                  "description": "len jedna skupina: ľudia, notifikácie, newslettre, pozvánky, faktúry a platby"],
        "unread_only": ["type": "boolean"], "limit": ["type": "integer", "description": "predvolene 30, max 200"]]]],
    ["name": "search", "description": "Hľadá v predmete, odosielateľovi, adresátoch a stiahnutom texte správ.",
     "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "account": ["type": "string"], "limit": ["type": "integer"]],
                     "required": ["query"]]],
    ["name": "read_message", "description": "Celá správa podľa id (z list_messages / search): hlavičky, text a prílohy. Ak telo ešte nie je stiahnuté, stiahne ho cez appku Courier.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "thread", "description": "Celá konverzácia (vlákno) k správe podľa id, od najstaršej, s textom stiahnutých správ.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "set_ticket",
     "description": "Lokálny ticketing v Courieri: nastaví stav konverzácií (open = otvorené, waiting = čaká sa, done = hotovo, none = bez stavu) a pridá/odoberie štítky (nový štítok sa vytvorí). Na server nič nezapisuje. Keď niekto odpíše do čakajúcej alebo hotovej konverzácie, sama sa vráti na open.",
     "inputSchema": ["type": "object", "properties": [
        "id": ["type": "integer"], "ids": ["type": "array", "items": ["type": "integer"]],
        "status": ["type": "string", "enum": ["open", "waiting", "done", "none"]],
        "add_tags": ["type": "array", "items": ["type": "string"]], "remove_tags": ["type": "array", "items": ["type": "string"]]]]],
    ["name": "tickets",
     "description": "Tiketová nástenka: bez parametrov počty a konverzácie v stavoch open / waiting / done; so status alebo tag len tie.",
     "inputSchema": ["type": "object", "properties": ["status": ["type": "string", "enum": ["open", "waiting", "done"]], "tag": ["type": "string"],
                                                       "limit": ["type": "integer"]]]],
    ["name": "tags", "description": "Štítky v Courieri s farbou a počtom konverzácií.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "manage_tag",
     "description": "Správa štítkov: action create (name, color), rename (name → new_name, aj na všetkých konverzáciách), recolor, delete. Farby: blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, gray.",
     "inputSchema": ["type": "object", "properties": ["action": ["type": "string", "enum": ["create", "rename", "recolor", "delete"]],
                                                       "name": ["type": "string"], "new_name": ["type": "string"], "color": ["type": "string"]],
                     "required": ["name"]]],
    ["name": "draft",
     "description": "PREDVOLENÝ spôsob písania: uloží e-mail ako koncept do priečinka Koncepty (používateľ ho dokončí a odošle v Courieri). reply_to = id správy, na ktorú sa odpovedá (doplní príjemcu, predmet a vlákno).",
     "inputSchema": ["type": "object", "properties": [
        "account": ["type": "string", "description": "e-mail účtu odosielateľa"], "to": ["type": "string"], "cc": ["type": "string"], "bcc": ["type": "string"],
        "subject": ["type": "string"], "body": ["type": "string", "description": "čistý text"], "reply_to": ["type": "integer"],
        "attachments": ["type": "array", "items": ["type": "string"], "description": "cesty k súborom"],
        "signature": ["type": "string", "description": "názov podpisu alebo none; predvolene podpis účtu"]]]],
    ["name": "propose_send",
     "description": "Krok 1 odoslania: vráti náhľad e-mailu (nič neodošle). Použi LEN keď používateľ výslovne chce správu odoslať (inak draft). S send_at sa správa naplánuje: Courier ju odošle sám v ten čas (používateľ ju vidí, upraví či zruší v Na odoslanie); takto rieš každé „pošli to v pondelok o 8:00“, nie timerom. Odosielaš existujúci koncept? Daj draft_id (id z draft), koncept po odoslaní zmizne z Konceptov.",
     "inputSchema": sendSchema, "annotations": ["readOnlyHint": true]],
    ["name": "commit_mail",
     "description": "Krok 2: odošle e-mail z propose_send, s rovnakými údajmi, až keď používateľ náhľad výslovne schválil.",
     "inputSchema": sendSchema, "annotations": ["destructiveHint": true]],
    ["name": "outbox",
     "description": "Na odoslanie: naplánované správy (a tie, ktoré sa nepodarilo odoslať) s id, časom, odosielateľom, príjemcami, predmetom a začiatkom textu.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "outbox_update",
     "description": "Zmena naplánovanej správy podľa id z outbox: cancel (zruší plán, správa sa vráti do Konceptov, nič sa nestratí), reschedule (nový send_at, YYYY-MM-DDTHH:mm), send_now (odošle hneď; len keď to používateľ výslovne chce). Text sa tu nemení: na to cancel a nový propose_send.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "string"], "action": ["type": "string", "enum": ["cancel", "reschedule", "send_now"]],
                                                       "send_at": ["type": "string"]], "required": ["id", "action"]],
     "annotations": ["destructiveHint": true]],
    ["name": "attachments",
     "description": "Hľadá prílohy naprieč všetkými schránkami (aj v histórii) podľa názvu súboru, odosielateľa alebo predmetu. Vráti message_id a index na save_attachment.",
     "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "account": ["type": "string"], "limit": ["type": "integer"]]]],
    ["name": "save_attachment",
     "description": "Stiahne prílohu na disk (predvolene ~/Downloads) a vráti cestu k súboru, napr. na ďalšie spracovanie alebo preposlanie.",
     "inputSchema": ["type": "object", "properties": [
        "message_id": ["type": "integer"], "index": ["type": "integer"], "filename": ["type": "string"],
        "dir": ["type": "string", "description": "cieľový priečinok"]], "required": ["message_id"]]],
    ["name": "groups",
     "description": "Prehľad skupín v doručenej pošte (ľudia, notifikácie, newslettre, pozvánky, faktúry a platby): počty, neprečítané, posledné.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "set_sender_group",
     "description": "Zaradí odosielateľa natrvalo do skupiny (people, notifications, newsletters, invites, invoices); bez group vráti automatiku.",
     "inputSchema": ["type": "object", "properties": ["sender": ["type": "string"], "group": ["type": "string"]], "required": ["sender"]]],
    ["name": "mark_read", "description": "Označí správy (celé konverzácie) ako prečítané, alebo read: false ako neprečítané.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "ids": ["type": "array", "items": ["type": "integer"]], "read": ["type": "boolean"]]],
     "annotations": ["readOnlyHint": false, "destructiveHint": true]],
    ["name": "mark_spam",
     "description": "spam: true presunie konverzácie do priečinka Spam (filter servera sa z toho učí); spam: false vráti správy zo Spamu do Doručenej pošty.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "ids": ["type": "array", "items": ["type": "integer"]], "spam": ["type": "boolean"]]]],
    ["name": "archive", "description": "Presunie konverzácie do Archívu.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "ids": ["type": "array", "items": ["type": "integer"]]]]],
    ["name": "propose_delete", "description": "Krok 1: náhľad, čo by sa presunulo do Koša (permanent: true = natrvalo). Nič nezmení.",
     "inputSchema": deleteSchema, "annotations": ["readOnlyHint": true]],
    ["name": "commit_trash", "description": "Krok 2: presunie konverzácie do Koša (alebo natrvalo) po súhlase používateľa s propose_delete.",
     "inputSchema": deleteSchema, "annotations": ["destructiveHint": true]],
    ["name": "propose_move", "description": "Krok 1: náhľad presunu konverzácií do priečinka (názov z folders). Nič nezmení.",
     "inputSchema": moveSchema, "annotations": ["readOnlyHint": true]],
    ["name": "commit_move", "description": "Krok 2: presunie konverzácie do priečinka po súhlase používateľa s propose_move.",
     "inputSchema": moveSchema, "annotations": ["destructiveHint": true]],
    ["name": "propose_unsubscribe",
     "description": "Krok 1: náhľad odhlásenia z newslettra alebo mailing listu (podľa hlavičky List-Unsubscribe). Pre každého odosielateľa ukáže spôsob (oneClick = Courier to urobí sám, mail = pošle odhlasovací e-mail z účtu používateľa, web = treba dokončiť v prehliadači) a koľko jeho správ by sa archivovalo. Stačí id jednej jeho správy (alebo ids, alebo sender = adresa). Nič nezmení.",
     "inputSchema": unsubscribeSchema, "annotations": ["readOnlyHint": true]],
    ["name": "commit_unsubscribe",
     "description": "Krok 2: po súhlase používateľa s propose_unsubscribe odhlási, zaradí odosielateľa do Newslettrov a (archive, predvolene áno) archivuje jeho správy z Doručenej pošty. Pri spôsobe web otvorí stránku v prehliadači.",
     "inputSchema": unsubscribeSchema, "annotations": ["destructiveHint": false, "openWorldHint": true]],
    ["name": "signatures", "description": "Podpisy v Courieri a ku ktorým účtom sú predvolené.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "sync", "description": "Stiahne novú poštu zo serverov (všetky účty, jeden účet alebo jeden priečinok).",
     "inputSchema": ["type": "object", "properties": ["account": ["type": "string"], "folder": ["type": "string"]]]],
    ["name": "open_in_courier", "description": "Otvorí správu v appke Courier.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
]

let tools: [[String: Any]] = toolDefs.map { t in
    var t = t
    if t["annotations"] == nil, let n = t["name"] as? String, readOnly.contains(n) { t["annotations"] = ["readOnlyHint": true] }
    return t
}

func addresses(_ v: Any?) -> [EmailAddress] {
    if let s = v as? String { return MIME.parseAddresses(s) }
    if let l = v as? [String] { return l.flatMap { MIME.parseAddresses($0) } }
    return []
}

/// Builds an outgoing message from tool arguments; a reply_to id fills in recipient, subject and threading headers.
/// The draft being sent (draft_id): it must be in a Drafts folder.
func sourceDraft(_ a: [String: Any]) throws -> MessageSummary? {
    guard let did = (a["draft_id"] as? NSNumber)?.int64Value else { return nil }
    guard let d = store.message(id: did),
          store.folders(account: d.accountID).first(where: { $0.path == d.folder })?.role == .drafts else {
        throw ToolError(message: "draft_id \(did) nie je koncept (už odišiel alebo bol zmazaný?). Pozri list_messages s folder drafts.")
    }
    return d
}

func outgoing(_ a: [String: Any]) throws -> OutgoingMessage {
    var account = resolveAccount(a["account"])
    var subject = a["subject"] as? String ?? ""
    var to = addresses(a["to"])
    var inReplyTo: String?
    var refs: [String] = []
    var body = a["body"] as? String ?? ""
    var cc = addresses(a["cc"])
    if let d = try sourceDraft(a) {
        // what is not given comes from the draft
        account = account ?? store.accounts().first { $0.id == d.accountID }
        if subject.isEmpty { subject = d.subject }
        if to.isEmpty { to = addresses(d.to) }
        if store.body(id: d.id) == nil { _ = askApp(["cmd": "fetch_body", "id": d.id]) }   // the draft's text, downloaded by the app
        let stored = store.body(id: d.id)
        if cc.isEmpty, let line = stored?.cc { cc = addresses(line) }
        if body.isEmpty {
            guard let text = stored?.text ?? stored?.html.map(MIME.stripHTML) else {
                throw ToolError(message: "Text konceptu ešte nie je stiahnutý: zavolaj read_message s jeho id alebo pošli body.")
            }
            body = text
        }
        let h = store.threadHeaders(id: d.id)
        if let r = h.references.last { inReplyTo = r; refs = h.references }
    }
    if let rid = (a["reply_to"] as? NSNumber)?.int64Value {
        guard let orig = store.message(id: rid) else { throw ToolError(message: "Správa reply_to nenájdená.") }
        account = account ?? store.accounts().first { $0.id == orig.accountID }
        if to.isEmpty { to = [EmailAddress(name: orig.fromName, address: orig.fromAddress)] }
        if subject.isEmpty { subject = orig.subject.lowercased().hasPrefix("re:") ? orig.subject : "Re: \(orig.subject)" }
        let h = store.threadHeaders(id: rid)
        if !h.messageID.isEmpty { inReplyTo = h.messageID; refs = h.references + [h.messageID] }
    }
    guard let acc = account ?? store.accounts().first else { throw ToolError(message: "Chýba účet (account).") }
    let files = (a["attachments"] as? [String] ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    for f in files where !FileManager.default.fileExists(atPath: f.path) { throw ToolError(message: "Príloha neexistuje: \(f.path)") }
    return OutgoingMessage(accountID: acc.id, to: to, cc: cc, bcc: addresses(a["bcc"]), subject: subject,
                           body: body, inReplyTo: inReplyTo, references: refs, attachments: files)
}

/// "2026-11-09T08:00" (local), with seconds or a zone too; must be in the future, at most a year ahead.
func sendAt(_ v: Any?) throws -> Date? {
    guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    var d: Date?
    for p in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] where d == nil { f.dateFormat = p; d = f.date(from: s) }
    if d == nil { d = ISO8601DateFormatter().date(from: s) }
    guard let d else { throw ToolError(message: "send_at musí byť YYYY-MM-DDTHH:mm (miestny čas).") }
    guard d.timeIntervalSinceNow > 60 else { throw ToolError(message: "send_at je v minulosti alebo o menej než minútu: na hneď použi commit_mail bez send_at.") }
    guard d.timeIntervalSinceNow < 366 * 86400 else { throw ToolError(message: "send_at najviac rok dopredu.") }
    return d
}

func local(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "sk_SK"); f.dateFormat = "EEE d. M. yyyy HH:mm"; return f.string(from: d)
}

func preview(_ m: OutgoingMessage) -> [String: Any] {
    var d: [String: Any] = ["from": store.accounts().first { $0.id == m.accountID }?.email ?? "", "to": m.to.map(\.full), "subject": m.subject, "body": m.body]
    if !m.cc.isEmpty { d["cc"] = m.cc.map(\.full) }
    if !m.bcc.isEmpty { d["bcc"] = m.bcc.map(\.full) }
    if m.inReplyTo != nil { d["reply"] = true }
    if !m.attachments.isEmpty { d["attachments"] = m.attachments.map(\.lastPathComponent) }
    return d
}

func call(_ name: String, _ a: [String: Any]) throws -> Any {
    let accounts = accountsByID()
    tickets = store.tickets()
    store.reloadOverrides()
    let limit = min(200, max(1, (a["limit"] as? NSNumber)?.intValue ?? 30))
    switch name {
    case "accounts":
        let folders = store.folders()
        return accounts.values.sorted { $0.sort < $1.sort }.map { acc -> [String: Any] in
            ["id": acc.id, "email": acc.email, "name": acc.name,
             "inbox_unread": folders.first { $0.accountID == acc.id && $0.role == .inbox }?.unread ?? 0]
        }
    case "folders":
        guard let acc = resolveAccount(a["account"]) else { throw ToolError(message: "Účet nenájdený. Použi accounts.") }
        return store.folders(account: acc.id).map { f -> [String: Any] in
            ["path": ModifiedUTF7.decode(f.path), "name": f.displayName, "role": f.role.rawValue, "unread": f.unread, "total": f.total]
        }
    case "projects":
        return store.projects().map { p -> [String: Any] in
            ["id": p.id, "name": p.name, "unread": store.unreadCount(project: p),
             "sources": p.sources.map { s -> String in
                switch s.kind {
                case .account: return "schránka \(accounts[s.accountID ?? ""]?.email ?? "?")"
                case .folder: return "priečinok \(ModifiedUTF7.decode(s.folder ?? "")) (\(accounts[s.accountID ?? ""]?.email ?? "?"))"
                case .sender: return "odosielateľ \(s.pattern ?? "")"
                }
             }]
        }
    case "list_messages":
        let unread = (a["unread_only"] as? Bool) ?? false
        var list: [MessageSummary]
        if a["project"] != nil {
            guard let p = resolveProject(a["project"]) else { throw ToolError(message: "Projekt nenájdený. Použi projects.") }
            list = store.messages(project: p, unreadOnly: unread, limit: limit)
        } else if a["account"] != nil {
            guard let acc = resolveAccount(a["account"]) else { throw ToolError(message: "Účet nenájdený. Použi accounts.") }
            guard let f = resolveFolder(acc, a["folder"]) else { throw ToolError(message: "Priečinok nenájdený. Použi folders.") }
            list = store.messages(account: acc.id, folder: f.path, limit: unread ? 2000 : limit).filter { !unread || !$0.seen }
        } else if let s = (a["status"] as? String).flatMap(TicketStatus.init) {
            list = store.messages(status: s, tag: a["tag"] as? String)
        } else if let tag = a["tag"] as? String {
            list = store.messages(tag: tag)
        } else {
            list = store.unifiedInbox(unreadOnly: unread, limit: limit * 3)
        }
        // One entry per conversation (its newest message), optionally one group only.
        var seen = Set<String>()
        let group = (a["group"] as? String).flatMap(MailCategory.init)
        return list.filter { seen.insert($0.threadKey).inserted && (group == nil || $0.category == group) }.prefix(limit).map { messageJSON($0, accounts) }
    case "search":
        guard let q = a["query"] as? String, !q.isEmpty else { throw ToolError(message: "Chýba query.") }
        return store.search(q, account: resolveAccount(a["account"])?.id, limit: limit).map { messageJSON($0, accounts) }
    case "read_message":
        guard let id = (a["id"] as? NSNumber)?.int64Value, let m = store.message(id: id) else { throw ToolError(message: "Správa nenájdená.") }
        var body = store.body(id: id)
        if body == nil {
            let r = askApp(["cmd": "fetch_body", "id": id])
            if r["ok"] as? Bool != true { throw ToolError(message: "Telo správy sa nepodarilo stiahnuť: \(r["error"] ?? "?")") }
            body = store.body(id: id)
        }
        var d = messageJSON(m, accounts)
        d["to"] = m.to
        if let b = body {
            if !b.cc.isEmpty { d["cc"] = b.cc }
            d["text"] = b.text ?? b.html.map(MIME.stripHTML).map { $0.replacingOccurrences(of: "\n\\s*\n\\s*\n+", with: "\n\n", options: .regularExpression) } ?? ""
            if !b.attachments.isEmpty { d["attachments"] = b.attachments.map { ["filename": $0.filename, "type": $0.mimeType, "size": $0.size] } }
        }
        return d
    case "thread":
        guard let id = (a["id"] as? NSNumber)?.int64Value, let m = store.message(id: id) else { throw ToolError(message: "Správa nenájdená.") }
        return store.thread(account: m.accountID, id: m.threadID).map { x -> [String: Any] in
            var d = messageJSON(x, accounts)
            if let b = store.body(id: x.id) { d["text"] = b.text ?? b.html.map(MIME.stripHTML) ?? "" }
            return d
        }
    case "set_ticket":
        let ids = (a["ids"] as? [NSNumber]) ?? ((a["id"] as? NSNumber).map { [$0] } ?? [])
        let msgs = ids.compactMap { store.message(id: $0.int64Value) }
        guard !msgs.isEmpty else { throw ToolError(message: "Správa nenájdená (id alebo ids).") }
        var out: [[String: Any]] = []
        for m in msgs {
            var t = tickets[m.threadKey] ?? Ticket(accountID: m.accountID, threadID: m.threadID)
            if let s = a["status"] as? String { t.status = s == "none" ? nil : TicketStatus(rawValue: s) }
            for tag in a["add_tags"] as? [String] ?? [] where !t.tags.contains(tag) {
                t.tags.append(tag)
                if !store.tags().contains(where: { $0.name == tag }) {
                    let colors = ["blue", "purple", "pink", "orange", "green", "teal", "red", "indigo"]
                    try store.save(Tag(name: tag, color: colors[store.tags().count % colors.count]))
                }
            }
            let remove = Set(a["remove_tags"] as? [String] ?? [])
            t.tags.removeAll { remove.contains($0) }
            try store.save(t)
            tickets[m.threadKey] = t
            out.append(["id": m.id, "subject": m.subject, "status": t.status?.rawValue ?? "none", "tags": t.tags])
        }
        _ = askApp(["cmd": "reload"], launch: false)
        return out
    case "tags":
        let all = store.tickets().values
        return store.tags().map { t -> [String: Any] in
            ["name": t.name, "color": t.color, "conversations": all.filter { $0.tags.contains(t.name) }.count]
        }
    case "tickets":
        // Conversations with a status (and/or tag): the ticket board.
        let s = (a["status"] as? String).flatMap(TicketStatus.init)
        let tag = a["tag"] as? String
        var seen = Set<String>()
        let list = store.messages(status: s, tag: tag).filter { seen.insert($0.threadKey).inserted }
        if s == nil && tag == nil {
            return TicketStatus.allCases.map { st -> [String: Any] in
                var seen2 = Set<String>()
                let l = store.messages(status: st).filter { seen2.insert($0.threadKey).inserted }
                return ["status": st.rawValue, "title": st.title, "count": l.count, "items": l.prefix(limit).map { messageJSON($0, accounts) }]
            }
        }
        return list.prefix(limit).map { messageJSON($0, accounts) }
    case "manage_tag":
        guard let n = a["name"] as? String, !n.isEmpty else { throw ToolError(message: "Chýba name.") }
        switch a["action"] as? String ?? "create" {
        case "create":
            try store.save(Tag(name: n, color: a["color"] as? String ?? "blue"))
        case "rename":
            guard let to = a["new_name"] as? String, !to.isEmpty else { throw ToolError(message: "Chýba new_name.") }
            try store.renameTag(n, to: to)
        case "recolor":
            try store.save(Tag(name: n, color: a["color"] as? String ?? "blue"))
        case "delete":
            try store.deleteTag(n)
        default: throw ToolError(message: "action: create, rename, recolor alebo delete")
        }
        _ = askApp(["cmd": "reload"], launch: false)
        return ["ok": true, "tags": store.tags().map(\.name)]
    case "draft":
        let m = try outgoing(a)
        var req: [String: Any] = ["cmd": "draft", "message": try JSONSerialization.jsonObject(with: JSONEncoder().encode(m))]
        if let s = a["signature"] as? String { req["signature"] = s }
        let r = askApp(req)
        if r["ok"] as? Bool != true { throw ToolError(message: "Koncept sa neuložil: \(r["error"] ?? "?")") }
        var out: [String: Any] = ["ok": true, "saved_to": "Koncepty", "draft": preview(m)]
        if let id = r["id"] { out["id"] = id; out["note"] = "Na odoslanie tohto konceptu daj propose_send / commit_mail s draft_id: \(id), po odoslaní zmizne z Konceptov." }
        return out
    case "propose_send", "commit_mail":
        let m = try outgoing(a)
        guard !m.recipients.isEmpty else { throw ToolError(message: "Chýba príjemca (to).") }
        let at = try sendAt(a["send_at"])
        let draft = try sourceDraft(a) ?? store.matchingDraft(account: m.accountID, subject: m.subject, to: m.to)
        guard name == "commit_mail" else {
            var p = preview(m)
            if let draft { p["replaces_draft"] = draft.id }
            if let at { p["send_at"] = local(at) }
            return ["sent": false, "preview": p,
                    "next": at == nil ? "Ukáž používateľovi tento náhľad. Až keď výslovne povie, že to má odísť, zavolaj commit_mail s rovnakými údajmi."
                        : "Ukáž používateľovi tento náhľad aj čas odoslania. Až keď výslovne súhlasí, zavolaj commit_mail s rovnakými údajmi (aj send_at); Courier ju potom odošle sám."]
        }
        var req: [String: Any] = ["cmd": at == nil ? "send" : "schedule", "message": try JSONSerialization.jsonObject(with: JSONEncoder().encode(m))]
        if let s = a["signature"] as? String { req["signature"] = s }
        // the draft's own text already has its signature
        if a["draft_id"] != nil, (a["body"] as? String ?? "").isEmpty, a["signature"] == nil { req["signature"] = "none" }
        if let did = (a["draft_id"] as? NSNumber)?.int64Value { req["draft_id"] = did }
        if let at { req["send_at"] = at.timeIntervalSince1970 }
        let r = askApp(req)
        if let at {
            if r["ok"] as? Bool != true { throw ToolError(message: "Nenaplánované: \(r["error"] ?? "?")") }
            return ["sent": false, "scheduled": local(at), "outbox_id": r["id"] ?? "", "message": preview(m),
                    "note": "Čaká v Courieri v Na odoslanie; Courier ju odošle v ten čas, keď beží (inak hneď po spustení). Zmeniť či zrušiť: outbox_update."]
        }
        if r["ok"] as? Bool != true { throw ToolError(message: "Neodoslané: \(r["error"] ?? "?")") }
        var out: [String: Any] = ["sent": true, "message": preview(m)]
        if let d = r["draft_removed"] { out["draft_removed"] = d }
        return out
    case "outbox":
        let items = store.outbox()
        if items.isEmpty { return ["outbox": [], "note": "Nič nečaká na odoslanie."] }
        return items.map { i -> [String: Any] in
            var d: [String: Any] = ["id": i.id, "send_at": local(i.sendAt), "from": accounts[i.message.accountID]?.email ?? "",
                                    "to": i.message.to.map(\.full), "subject": i.message.subject,
                                    "body_start": String(i.message.body.prefix(200))]
            if !i.message.cc.isEmpty { d["cc"] = i.message.cc.map(\.full) }
            if !i.message.attachments.isEmpty { d["attachments"] = i.message.attachments.map(\.lastPathComponent) }
            if let e = i.error { d["error"] = e }
            return d
        }
    case "outbox_update":
        guard let id = a["id"] as? String, let action = a["action"] as? String else { throw ToolError(message: "Chýba id alebo action.") }
        guard let item = store.outbox().first(where: { $0.id == id }) else { throw ToolError(message: "Táto správa už nie je v Na odoslanie. Pozri outbox.") }
        var req: [String: Any] = ["cmd": "outbox", "id": id, "action": action]
        if action == "reschedule" {
            guard let at = try sendAt(a["send_at"]) else { throw ToolError(message: "reschedule potrebuje send_at.") }
            req["send_at"] = at.timeIntervalSince1970
        }
        let r = askApp(req)
        if r["ok"] as? Bool != true { throw ToolError(message: "Nepodarilo sa: \(r["error"] ?? "?")") }
        let now = store.outbox().first { $0.id == id }
        return ["ok": true, "action": action, "subject": item.message.subject,
                "result": action == "cancel" ? "plán zrušený, správa je v Konceptoch" : action == "send_now" ? "odosiela sa" : "nový čas \(now.map { local($0.sendAt) } ?? "?")"]
    case "attachments":
        let q = a["query"] as? String ?? ""
        return store.attachmentHits(q, account: resolveAccount(a["account"])?.id, limit: limit).map { h -> [String: Any] in
            ["message_id": h.message.id, "index": h.index, "filename": h.attachment.filename, "type": h.attachment.mimeType,
             "size": h.attachment.size, "from": h.message.fromDisplay, "subject": h.message.subject, "date": iso.string(from: h.message.date),
             "account": accounts[h.message.accountID]?.email ?? ""]
        }
    case "save_attachment":
        guard let id = (a["message_id"] as? NSNumber)?.int64Value, store.message(id: id) != nil else { throw ToolError(message: "Správa nenájdená.") }
        var req: [String: Any] = ["cmd": "save_attachment", "id": id, "index": (a["index"] as? NSNumber)?.intValue ?? 0]
        if let f = a["filename"] as? String { req["filename"] = f }
        if let d = a["dir"] as? String { req["dir"] = d }
        let r = askApp(req)
        if r["ok"] as? Bool != true { throw ToolError(message: "Prílohu sa nepodarilo uložiť: \(r["error"] ?? "?")") }
        return ["ok": true, "path": r["path"] ?? ""]
    case "groups":
        let list = store.unifiedInbox(limit: 3000)
        var seen = Set<String>()
        let heads = list.filter { seen.insert($0.threadKey).inserted }
        return MailCategory.allCases.map { c -> [String: Any] in
            let l = heads.filter { $0.category == c }
            return ["group": c.rawValue, "title": c.title, "conversations": l.count, "unread": l.filter { !$0.seen }.count,
                    "latest": l.prefix(3).map { "\($0.fromDisplay): \($0.subject)" }]
        }
    case "set_sender_group":
        guard let addr = a["sender"] as? String, addr.contains("@") else { throw ToolError(message: "Chýba sender (e-mail).") }
        let g = (a["group"] as? String).flatMap(MailCategory.init)
        try store.setSenderCategory(addr, g)
        return ["ok": true, "sender": addr, "group": g?.rawValue ?? "auto"]
    case "mark_read":
        let ids = (a["ids"] as? [NSNumber]) ?? ((a["id"] as? NSNumber).map { [$0] } ?? [])
        guard !ids.isEmpty else { throw ToolError(message: "Chýba id alebo ids.") }
        let r = askApp(["cmd": "seen", "ids": ids, "seen": (a["read"] as? Bool) ?? true])
        if r["ok"] as? Bool != true { throw ToolError(message: "\(r["error"] ?? "?")") }
        return r
    case "mark_spam":
        let ids = (a["ids"] as? [NSNumber]) ?? ((a["id"] as? NSNumber).map { [$0] } ?? [])
        guard !ids.isEmpty else { throw ToolError(message: "Chýba id alebo ids.") }
        let spam = (a["spam"] as? Bool) ?? true
        let r = askApp(["cmd": "move", "ids": ids, "target": spam ? "junk" : "inbox", "whole_thread": spam])
        if r["ok"] as? Bool != true { throw ToolError(message: "\(r["error"] ?? "?")") }
        return r
    case "archive", "propose_delete", "commit_trash", "propose_move", "commit_move":
        let ids = (a["ids"] as? [NSNumber]) ?? ((a["id"] as? NSNumber).map { [$0] } ?? [])
        guard !ids.isEmpty else { throw ToolError(message: "Chýba id alebo ids.") }
        let target: String
        switch name {
        case "archive": target = "archive"
        case "propose_delete", "commit_trash": target = (a["permanent"] as? Bool) == true ? "permanent" : "trash"
        default:
            guard let f = a["folder"] as? String, !f.isEmpty else { throw ToolError(message: "Chýba folder.") }
            target = f
        }
        let msgs = ids.compactMap { store.message(id: $0.int64Value) }
        // Moving mail away is a write: preview first, act after the user's yes (confirm: true). Archive is reversible enough to skip it.
        if name.hasPrefix("propose_") {
            return ["done": false, "would": name.hasSuffix("delete") ? (target == "permanent" ? "vymazať natrvalo" : "presunúť do Koša") : "presunúť do \(target)",
                    "messages": msgs.map { "\($0.fromDisplay): \($0.subject)" },
                    "next": "Ukáž to používateľovi a po jeho súhlase zavolaj \(name == "propose_delete" ? "commit_trash" : "commit_move") s rovnakými údajmi."]
        }
        let r = askApp(["cmd": "move", "ids": ids, "target": target, "whole_thread": (a["whole_thread"] as? Bool) ?? true])
        if r["ok"] as? Bool != true { throw ToolError(message: "\(r["error"] ?? "?")") }
        return r
    case "propose_unsubscribe", "commit_unsubscribe":
        var msgs = ((a["ids"] as? [NSNumber]) ?? ((a["id"] as? NSNumber).map { [$0] } ?? [])).compactMap { store.message(id: $0.int64Value) }
        if let s = a["sender"] as? String, !s.isEmpty {
            guard let m = store.messages(from: s).first ?? store.search(s, limit: 1).first(where: { $0.fromAddress.lowercased() == s.lowercased() })
            else { throw ToolError(message: "Od \(s) nemám v Doručenej pošte žiadnu správu.") }
            msgs.append(m)
        }
        guard !msgs.isEmpty else { throw ToolError(message: "Chýba id, ids alebo sender.") }
        var seen = Set<String>()
        let perSender = msgs.filter { seen.insert($0.fromAddress.lowercased()).inserted }
        let run = name == "commit_unsubscribe"
        let results = perSender.map { m -> [String: Any] in
            askApp(["cmd": "unsubscribe", "id": m.id, "run": run, "archive": (a["archive"] as? Bool) ?? true])
        }
        if run { return ["done": true, "results": results] }
        return ["done": false, "senders": results,
                "next": "Ukáž to používateľovi (pri spôsobe mail sa z jeho účtu odošle e-mail) a po jeho súhlase zavolaj commit_unsubscribe s rovnakými údajmi."]
    case "signatures":
        return ((try? store.signatures()) ?? []).map { s -> [String: Any] in
            ["name": s.name, "html": s.isHTML, "default_for": store.accounts().filter { store.defaultSignature(account: $0.id) == s.id }.map(\.email)]
        }
    case "sync":
        var req: [String: Any] = ["cmd": "sync"]
        if let acc = resolveAccount(a["account"]) {
            req["account"] = acc.id
            if a["folder"] != nil, let f = resolveFolder(acc, a["folder"]) { req["folder"] = f.path }
        }
        return askApp(req)
    case "open_in_courier":
        guard let id = (a["id"] as? NSNumber)?.int64Value else { throw ToolError(message: "Chýba id.") }
        return askApp(["cmd": "show", "id": id])
    default:
        throw ToolError(message: "Neznámy nástroj \(name)")
    }
}

// MARK: JSON-RPC loop

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write(Data([0x0A]))
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
    guard let id = msg["id"] else { continue }   // notifications
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "courier", "version": "0.1"],
            "instructions": "Courier je lokálny e-mailový klient používateľa (viac účtov, projekty na nástenke). Na poštu použi list_messages / search / read_message; projects ukáže, ako má používateľ poštu rozdelenú podľa projektov, thread celé vlákno. Písanie: predvolene draft (koncept); odoslanie len keď to používateľ výslovne chce: propose_send (náhľad) a po jeho súhlase commit_mail. Odoslanie neskôr (napr. v pondelok o 8:00): to isté so send_at, správa čaká v Na odoslanie a Courier ju odošle sám; outbox ich vypíše, outbox_update zruší (späť do Konceptov), presunie alebo odošle hneď. Mazanie a presun rovnako (propose_delete/commit_trash, propose_move/commit_move). Odhlásenie z newslettrov: propose_unsubscribe, po súhlase commit_unsubscribe. list_messages má skupiny (group: people, notifications, newsletters, invites, invoices); groups dá prehľad.",
        ] as [String: Any]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])

    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let result = try call(name, args)
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])) ?? Data()
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]])
        } catch {
            let text = (error as? ToolError)?.message ?? error.localizedDescription
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": true]])
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}
