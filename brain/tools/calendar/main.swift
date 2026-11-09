// brain-calendar: Apple Calendar through EventKit, so every account in Calendar (iCloud, Google, Exchange) works the same.
// Recurring events come expanded. Output is JSON on stdout; errors go to stderr with a non-zero exit.
//   brain-calendar calendars
//   brain-calendar events --from ISO --to ISO [--calendars id,id] [--query text]
//   brain-calendar create --calendar id --title t --start ISO --end ISO [--all-day] [--location l] [--notes n] [--url u]
//                         [--repeat daily|weekly|monthly|yearly [--interval n] [--days mo,th] [--until YYYY-MM-DD | --count n]]
//   brain-calendar update --id eventId [--occurrence ISO] [--span this|future] [--title ..] [--start ..] [--end ..] [--location ..] [--notes ..] [--calendar id]
//   brain-calendar delete --id eventId [--occurrence ISO] [--span this|future]
// Reminders (asks for Reminders access separately):
//   brain-calendar lists
//   brain-calendar reminders [--lists id,id] [--done] [--query text]
//   brain-calendar add-reminder --list id --title t [--notes n] [--due ISO] [--priority 1|5|9]
//   brain-calendar complete-reminder --id id   |   brain-calendar delete-reminder --id id
// Contacts (asks for Contacts access): brain-calendar contacts → names, nickname, company, phones, e-mails, birthday
// Output: {"result": ...} or {"error": "..."}.
import Contacts
import EventKit
import Foundation

let args = CommandLine.arguments
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
// Launched as an app (open -a ... --args --out file) so macOS asks for Calendar access for Brain itself; the result goes to --out.
let outFile = opt("--out")
func write(_ v: Any) {
    let d = try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
    if let f = outFile { try! d.write(to: URL(fileURLWithPath: f), options: .atomic) } else { FileHandle.standardOutput.write(d + "\n".data(using: .utf8)!) }
}
func die(_ msg: String, _ code: Int32 = 1) -> Never {
    if outFile != nil { write(["error": msg]) } else { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!) }
    exit(code)
}
func out(_ v: Any) { write(["result": v]) }

let isoFull = ISO8601DateFormatter()
let isoLocal: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f }()
let dayOnly: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
func parseDate(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    if let d = isoFull.date(from: s) { return d }
    if let d = isoLocal.date(from: String(s.prefix(19))) { return d }
    if let d = isoLocal.date(from: s.count == 16 ? s + ":00" : s) { return d }
    return dayOnly.date(from: String(s.prefix(10)))
}
func local(_ d: Date) -> String { isoLocal.string(from: d) }

let command = args.count > 1 ? args[1] : ""

if command == "contacts" {
    let cs = CNContactStore()
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    cs.requestAccess(for: .contacts) { g, _ in ok = g; sem.signal() }
    sem.wait()
    if !ok { die("no Contacts access: allow Brain Calendar in System Settings → Privacy & Security → Contacts", 3) }
    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey, CNContactIdentifierKey] as [CNKeyDescriptor]
    var out_: [[String: Any]] = []
    do {
        try cs.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            var o: [String: Any] = ["id": c.identifier, "given": c.givenName, "family": c.familyName]
            if !c.nickname.isEmpty { o["nickname"] = c.nickname }
            if !c.organizationName.isEmpty { o["company"] = c.organizationName }
            let phones = c.phoneNumbers.map { $0.value.stringValue }
            if !phones.isEmpty { o["phones"] = phones }
            let mails = c.emailAddresses.map { String($0.value) }
            if !mails.isEmpty { o["emails"] = mails }
            if let b = c.birthday, let m = b.month, let d = b.day { o["birthday"] = String(format: "%04d-%02d-%02d", b.year ?? 0, m, d) }
            out_.append(o)
        }
    } catch { die("contacts failed: \(error.localizedDescription)") }
    out(out_)
    exit(0)
}

// contacts-apply --file plan.json [--dry]: { "create": [{given, family, company?, emails: [], phones: []}],
//   "update": [{id, given?, family?, company?, add_emails: [], add_phones: []}] } — only adds or renames, never deletes.
if command == "contacts-apply" {
    guard let path = opt("--file"), let data = FileManager.default.contents(atPath: path),
          let plan = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { die("--file plan.json is required", 2) }
    let cs = CNContactStore()
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    cs.requestAccess(for: .contacts) { g, _ in ok = g; sem.signal() }
    sem.wait()
    if !ok { die("no Contacts access: allow Brain Calendar in System Settings → Privacy & Security → Contacts", 3) }
    let dry = args.contains("--dry")
    let req = CNSaveRequest()
    let work = { (e: String) -> String in e.range(of: #"@(gmail|icloud|me|yahoo|outlook|hotmail|centrum|azet|seznam|post|zoznam)\."#, options: .regularExpression) == nil ? CNLabelWork : CNLabelHome }
    var created = 0, updated = 0, missing: [String] = []
    for c in plan["create"] as? [[String: Any]] ?? [] {
        let m = CNMutableContact()
        m.givenName = c["given"] as? String ?? ""
        m.familyName = c["family"] as? String ?? ""
        if let o = c["company"] as? String { m.organizationName = o }
        m.emailAddresses = (c["emails"] as? [String] ?? []).map { CNLabeledValue(label: work($0), value: $0 as NSString) }
        m.phoneNumbers = (c["phones"] as? [String] ?? []).map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0)) }
        req.add(m, toContainerWithIdentifier: nil)
        created += 1
    }
    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
    for u in plan["update"] as? [[String: Any]] ?? [] {
        guard let id = u["id"] as? String, let c = try? cs.unifiedContact(withIdentifier: id, keysToFetch: keys) else { missing.append(u["id"] as? String ?? "?"); continue }
        let m = c.mutableCopy() as! CNMutableContact
        if let g = u["given"] as? String { m.givenName = g }
        if let f = u["family"] as? String { m.familyName = f }
        if let o = u["company"] as? String, m.organizationName.isEmpty { m.organizationName = o }
        for e in u["add_emails"] as? [String] ?? [] where !m.emailAddresses.contains(where: { ($0.value as String).lowercased() == e.lowercased() }) {
            m.emailAddresses.append(CNLabeledValue(label: work(e), value: e as NSString))
        }
        for p in u["add_phones"] as? [String] ?? [] { m.phoneNumbers.append(CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: p))) }
        req.update(m)
        updated += 1
    }
    if !dry { do { try cs.execute(req) } catch { die("save failed: \(error.localizedDescription)") } }
    out(["created": created, "updated": updated, "missing": missing, "dry": dry])
    exit(0)
}

let store = EKEventStore()
let forReminders = ["lists", "reminders", "add-reminder", "complete-reminder", "delete-reminder"].contains(command)
let sem = DispatchSemaphore(value: 0)
var granted = false
if #available(macOS 14.0, *) {
    if forReminders { store.requestFullAccessToReminders { ok, _ in granted = ok; sem.signal() } }
    else { store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() } }
} else {
    store.requestAccess(to: forReminders ? .reminder : .event) { ok, _ in granted = ok; sem.signal() }
}
sem.wait()
if !granted { die("no \(forReminders ? "Reminders" : "Calendar") access: allow Brain Calendar in System Settings → Privacy & Security → \(forReminders ? "Reminders" : "Calendars") (Full Access)", 3) }

func calInfo(_ c: EKCalendar) -> [String: Any] {
    ["id": c.calendarIdentifier, "title": c.title, "account": c.source?.title ?? "", "type": c.source.map { "\($0.sourceType.rawValue)" } ?? "",
     "writable": c.allowsContentModifications]
}
func eventInfo(_ e: EKEvent) -> [String: Any] {
    var o: [String: Any] = ["id": e.eventIdentifier ?? "", "title": e.title ?? "", "start": local(e.startDate), "end": local(e.endDate),
                            "all_day": e.isAllDay, "calendar": e.calendar.title, "calendar_id": e.calendar.calendarIdentifier,
                            "account": e.calendar.source?.title ?? "", "recurring": e.hasRecurrenceRules]
    if let l = e.location, !l.isEmpty { o["location"] = l }
    if let n = e.notes, !n.isEmpty { o["notes"] = String(n.prefix(20000)) }
    if let u = e.url { o["url"] = u.absoluteString }
    if let a = e.attendees, !a.isEmpty {
        o["attendees"] = a.map { p -> [String: Any] in
            var x: [String: Any] = ["name": p.name ?? "", "status": p.participantStatus.rawValue]
            let mail = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            if mail.contains("@") { x["email"] = mail }
            return x
        }
    }
    if let org = e.organizer { o["organizer"] = org.name ?? org.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
    if e.status == .canceled { o["canceled"] = true }
    if let r = e.recurrenceRules?.first { o["repeat"] = repeatInfo(r) }
    return o
}

// --repeat daily|weekly|monthly|yearly [--interval n] [--days mo,th] [--until YYYY-MM-DD | --count n] (neither = no end)
let weekdayCodes: [(String, EKWeekday)] = [("mo", .monday), ("tu", .tuesday), ("we", .wednesday), ("th", .thursday), ("fr", .friday), ("sa", .saturday), ("su", .sunday)]
let freqNames: [(String, EKRecurrenceFrequency)] = [("daily", .daily), ("weekly", .weekly), ("monthly", .monthly), ("yearly", .yearly)]
func repeatRule() -> EKRecurrenceRule? {
    guard let f = opt("--repeat") else { return nil }
    guard let freq = freqNames.first(where: { $0.0 == f })?.1 else { die("--repeat must be daily, weekly, monthly or yearly", 2) }
    let interval = opt("--interval").flatMap(Int.init) ?? 1
    let days = (opt("--days") ?? "").split(separator: ",").map { code -> EKRecurrenceDayOfWeek in
        guard let d = weekdayCodes.first(where: { $0.0 == String(code) })?.1 else { die("--days: unknown day \(code)", 2) }
        return EKRecurrenceDayOfWeek(d)
    }
    var end: EKRecurrenceEnd? = nil
    if let c = opt("--count").flatMap(Int.init) { end = EKRecurrenceEnd(occurrenceCount: c) }
    else if let u = opt("--until"), let d = dayOnly.date(from: u) { end = EKRecurrenceEnd(end: d.addingTimeInterval(86399)) }   // through the end of that day
    return EKRecurrenceRule(recurrenceWith: freq, interval: interval, daysOfTheWeek: days.isEmpty ? nil : days,
                            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
}
func repeatInfo(_ r: EKRecurrenceRule) -> [String: Any] {
    var o: [String: Any] = ["freq": freqNames.first(where: { $0.1 == r.frequency })?.0 ?? "\(r.frequency.rawValue)", "interval": r.interval]
    if let ds = r.daysOfTheWeek, !ds.isEmpty { o["days"] = ds.compactMap { d in weekdayCodes.first(where: { $0.1 == d.dayOfTheWeek })?.0 } }
    if let e = r.recurrenceEnd {
        if let d = e.endDate { o["until"] = dayOnly.string(from: d) } else { o["count"] = e.occurrenceCount }
    } else { o["end"] = "never" }
    return o
}
func findEvent() -> EKEvent {
    guard let id = opt("--id") else { die("--id is required", 2) }
    if let occ = parseDate(opt("--occurrence")) {
        // a specific occurrence of a recurring event: look it up around that time
        let es = store.events(matching: store.predicateForEvents(withStart: occ.addingTimeInterval(-86400), end: occ.addingTimeInterval(86400), calendars: nil))
        if let e = es.first(where: { $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince(occ)) < 60 }) { return e }
        die("no occurrence of \(id) at \(opt("--occurrence")!)")
    }
    guard let e = store.event(withIdentifier: id) else { die("no event \(id)") }
    return e
}
func span() -> EKSpan { opt("--span") == "future" ? .futureEvents : .thisEvent }
func apply(_ e: EKEvent) {
    if let t = opt("--title") { e.title = t }
    if args.contains("--all-day") { e.isAllDay = true }
    if let s = parseDate(opt("--start")) { e.startDate = s }
    if let s = parseDate(opt("--end")) { e.endDate = s }
    if let l = opt("--location") { e.location = l.isEmpty ? nil : l }
    if let n = opt("--notes") { e.notes = n.isEmpty ? nil : n }
    if let u = opt("--url") { e.url = u.isEmpty ? nil : URL(string: u) }
    if let cid = opt("--calendar") {
        guard let c = store.calendar(withIdentifier: cid) else { die("no calendar \(cid)") }
        e.calendar = c
    }
    attendees(e)
}

/// --add-attendees / --remove-attendees a@x.sk,b@y.com. EventKit only reads attendees publicly; this uses its own
/// (unpublished) EKAttendee and addAttendee:/removeAttendee:, as Calendar.app does. The calendar's server (Google, iCloud,
/// Exchange) then sends the invitations and cancellations.
func attendees(_ e: EKEvent) {
    let list = { (k: String) in (opt(k) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.contains("@") } }
    let add = list("--add-attendees"), remove = list("--remove-attendees")
    if add.isEmpty && remove.isEmpty { return }
    // On save EventKit also adds new attendees to the address recents and crashes there for attendees made this way
    // (a nil dictionary key in -[EKEvent _addNewAttendeesToRecentsIfNeeded]). Skipping it only skips that autocomplete hint.
    if let m = class_getInstanceMethod(EKEvent.self, Selector(("_addNewAttendeesToRecentsIfNeeded"))) {
        let noop: @convention(block) (AnyObject) -> Void = { _ in }
        method_setImplementation(m, imp_implementationWithBlock(noop))
    }
    guard let cls = NSClassFromString("EKAttendee") as? NSObject.Type,
          e.responds(to: Selector(("addAttendee:"))), e.responds(to: Selector(("removeAttendee:"))) else { die("this macOS can't add attendees through EventKit") }
    let mail = { (p: EKParticipant) in p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").lowercased() }
    for p in e.attendees ?? [] where remove.contains(mail(p)) { e.perform(Selector(("removeAttendee:")), with: p) }
    let have = Set((e.attendees ?? []).map(mail))
    for m in add where !have.contains(m) {
        let a = cls.init()
        a.setValue(m, forKey: "emailAddress")
        a.setValue(URL(string: "mailto:\(m)"), forKey: "URL")
        a.setValue(EKParticipantRole.required.rawValue, forKey: "participantRole")
        a.setValue(EKParticipantType.person.rawValue, forKey: "participantType")
        a.setValue(EKParticipantStatus.pending.rawValue, forKey: "participantStatus")
        e.perform(Selector(("addAttendee:")), with: a)
    }
}

func reminderInfo(_ r: EKReminder) -> [String: Any] {
    var o: [String: Any] = ["id": r.calendarItemIdentifier, "title": r.title ?? "", "list": r.calendar.title, "done": r.isCompleted]
    if let n = r.notes, !n.isEmpty { o["notes"] = String(n.prefix(1000)) }
    if let d = r.dueDateComponents, let date = Calendar.current.date(from: d) { o["due"] = d.hour == nil ? dayOnly.string(from: date) : local(date) }
    if r.priority > 0 { o["priority"] = r.priority }
    if let c = r.completionDate { o["completed"] = local(c) }
    return o
}
func findReminder() -> EKReminder {
    guard let id = opt("--id") else { die("--id is required", 2) }
    guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { die("no reminder \(id)") }
    return r
}

switch command {
case "lists":
    out(store.calendars(for: .reminder).map { ["id": $0.calendarIdentifier, "title": $0.title, "account": $0.source?.title ?? ""] })
case "reminders":
    let ids = opt("--lists")?.split(separator: ",").map(String.init)
    let cals = ids.map { $0.compactMap { store.calendar(withIdentifier: $0) } }
    let pred = args.contains("--done") ? store.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-30 * 86400), ending: nil, calendars: cals)
                                       : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
    var found: [EKReminder] = []
    store.fetchReminders(matching: pred) { rs in found = rs ?? []; sem.signal() }
    sem.wait()
    if let q = opt("--query")?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), !q.isEmpty {
        found = found.filter { (($0.title ?? "") + " " + ($0.notes ?? "")).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q) }
    }
    out(found.map(reminderInfo))
case "add-reminder":
    guard let lid = opt("--list"), let c = store.calendar(withIdentifier: lid) else { die("--list id is required (see lists)", 2) }
    guard let t = opt("--title") else { die("--title is required", 2) }
    let r = EKReminder(eventStore: store)
    r.calendar = c; r.title = t
    if let n = opt("--notes") { r.notes = n }
    if let p = opt("--priority").flatMap(Int.init) { r.priority = p }
    if let ds = opt("--due"), let d = parseDate(ds) {
        r.dueDateComponents = Calendar.current.dateComponents(ds.count > 10 ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: d)
        if ds.count > 10 { r.addAlarm(EKAlarm(absoluteDate: d)) }
    }
    do { try store.save(r, commit: true) } catch { die("save failed: \(error.localizedDescription)") }
    out(reminderInfo(r))
case "complete-reminder":
    let r = findReminder()
    r.isCompleted = true
    do { try store.save(r, commit: true) } catch { die("save failed: \(error.localizedDescription)") }
    out(reminderInfo(r))
case "delete-reminder":
    let r = findReminder()
    let info = reminderInfo(r)
    do { try store.remove(r, commit: true) } catch { die("delete failed: \(error.localizedDescription)") }
    out(["deleted": info])

case "calendars":
    out(store.calendars(for: .event).map(calInfo))
case "events":
    guard let from = parseDate(opt("--from")), let to = parseDate(opt("--to")) else { die("--from and --to are required", 2) }
    let ids = opt("--calendars")?.split(separator: ",").map(String.init)
    let cals = ids.map { $0.compactMap { store.calendar(withIdentifier: $0) } }
    var es = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: cals))
    if let q = opt("--query")?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), !q.isEmpty {
        es = es.filter { e in
            [e.title, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
    }
    out(es.sorted { $0.startDate < $1.startDate }.map(eventInfo))
case "create":
    guard let cid = opt("--calendar"), let c = store.calendar(withIdentifier: cid) else { die("--calendar id is required (see calendars)", 2) }
    guard opt("--title") != nil, parseDate(opt("--start")) != nil else { die("--title and --start are required", 2) }
    let e = EKEvent(eventStore: store)
    e.calendar = c
    apply(e)
    if e.endDate == nil { e.endDate = e.isAllDay ? e.startDate : e.startDate.addingTimeInterval(3600) }
    if let r = repeatRule() { e.addRecurrenceRule(r) }
    do { try store.save(e, span: e.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: true) } catch { die("save failed: \(error.localizedDescription)") }
    out(eventInfo(e))
case "update":
    let e = findEvent()
    apply(e)
    do { try store.save(e, span: span(), commit: true) } catch { die("save failed: \(error.localizedDescription)") }
    // the calendar server can refuse a move silently (Google keeps an event with invitees in the organizer's calendar)
    if let cid = opt("--calendar"), store.event(withIdentifier: e.eventIdentifier)?.calendar.calendarIdentifier ?? e.calendar.calendarIdentifier != cid {
        die("the event stayed in \(e.calendar.title): this calendar doesn't allow moving it (events with invitees usually can't change calendar). The other changes were saved; to have it in the other calendar, create it there and delete this one.")
    }
    out(eventInfo(e))
case "delete":
    let e = findEvent()
    let info = eventInfo(e)
    do { try store.remove(e, span: span(), commit: true) } catch { die("delete failed: \(error.localizedDescription)") }
    out(["deleted": info])
default:
    die("usage: brain-calendar calendars | events --from ISO --to ISO [--calendars ids] [--query q] | create | update | delete", 2)
}
