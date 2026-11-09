import Foundation
import Observation

/// One ticked-off chore: per day for day tasks, per period (its first day) for flexible ones.
public struct Completion: Codable, Hashable, Sendable {
    public var taskId: String
    public var day: Day
    public var done: Bool
    public var by: String?
    public var key: String { "\(taskId)@\(day)" }
}

/// A local change not yet in Supabase. Newer changes to the same row replace older ones.
enum Pending: Codable, Hashable {
    case task(HomeTask, deleted: Bool)
    case completion(Completion)
    case shop(ShopItem, deleted: Bool)

    var key: String {
        switch self {
        case .task(let t, _): "task:\(t.id)"
        case .completion(let c): "done:\(c.key)"
        case .shop(let s, _): "shop:\(s.id)"
        }
    }
}

/// Everything saved on this Mac (`household.json`).
struct HomeData: Codable {
    var household: HouseholdInfo?
    var tasks: [HomeTask] = []
    var completions: [String: Completion] = [:]
    var shopping: [ShopItem] = []
    var outbox: [Pending] = []
    /// Per table, the newest `updated_at` already pulled.
    var pulled: [String: String] = [:]
}

/// The household, local-first: every change is saved here at once and queued, then pushed to Supabase; changes from the
/// other members are pulled every 30 s (and right after a change). A row with a change still queued keeps the local
/// version; otherwise the newer server row wins.
@MainActor @Observable
public final class Store {
    public nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Home")
    }

    public let supabase: Supabase
    private var data: HomeData
    private let file: URL
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var syncing = false

    public private(set) var lastSync: Date?
    public private(set) var error: String?
    public private(set) var busy = false
    /// Signed in, but not a member of any household yet (create one or join with a code).
    public private(set) var needsHousehold = false

    public init(folder: URL = Store.folder, supabase: Supabase? = nil) {
        file = folder.appendingPathComponent("household.json")
        self.supabase = supabase ?? Supabase(folder: folder)
        data = (try? JSONDecoder.iso.decode(HomeData.self, from: Data(contentsOf: file))) ?? HomeData()
    }

    /// Demo data for `--snapshot` renders.
    public init(demo: Void) {
        file = URL(fileURLWithPath: "/dev/null")
        supabase = Supabase(folder: FileManager.default.temporaryDirectory.appendingPathComponent("home-demo"))
        data = Demo.data()
    }

    // MARK: Reading

    public var signedIn: Bool { supabase.signedIn }
    public var email: String? { supabase.session?.email }
    public var household: HouseholdInfo? { data.household }
    public var tasks: [HomeTask] { data.tasks }
    public var shopping: [ShopItem] { data.shopping }
    public var pendingCount: Int { data.outbox.count }
    public var members: [String] { data.household?.members.map(\.name) ?? [] }
    public var me: String? {
        guard let id = supabase.session?.userId else { return data.household?.members.first?.name }
        return data.household?.members.first { $0.userId == id }?.name
    }

    public func task(_ id: String) -> HomeTask? { data.tasks.first { $0.id == id } }

    public func isDone(_ t: HomeTask, on d: Day) -> Bool { data.completions["\(t.id)@\(t.doneDay(d))"]?.done == true }
    public func doneBy(_ t: HomeTask, on d: Day) -> String? { data.completions["\(t.id)@\(t.doneDay(d))"]?.by }

    // MARK: Changing

    public func save(_ t: HomeTask) {
        var t = t
        t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.title.isEmpty else { return }
        if let i = data.tasks.firstIndex(where: { $0.id == t.id }) { data.tasks[i] = t } else { data.tasks.append(t) }
        queue(.task(t, deleted: false))
    }

    public func delete(_ t: HomeTask) {
        data.tasks.removeAll { $0.id == t.id }
        queue(.task(t, deleted: true))
    }

    public func setDone(_ t: HomeTask, on d: Day, _ done: Bool) {
        let c = Completion(taskId: t.id, day: t.doneDay(d), done: done, by: done ? me : nil)
        if done { data.completions[c.key] = c } else { data.completions[c.key] = nil }
        queue(.completion(c))
    }

    /// Adds items to the shopping list; names already on it (not bought) are skipped. Returns what was added.
    @discardableResult
    public func addShopping(_ names: [String]) -> [ShopItem] {
        var added: [ShopItem] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !data.shopping.contains(where: { !$0.done && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
            else { continue }
            let item = ShopItem(name: name)
            data.shopping.append(item)
            queue(.shop(item, deleted: false), sync: false)
            added.append(item)
        }
        if !added.isEmpty { changed() }
        return added
    }

    public func setBought(_ item: ShopItem, _ done: Bool) {
        guard let i = data.shopping.firstIndex(where: { $0.id == item.id }) else { return }
        data.shopping[i].done = done
        queue(.shop(data.shopping[i], deleted: false))
    }

    public func rename(_ item: ShopItem, to name: String) {
        guard let i = data.shopping.firstIndex(where: { $0.id == item.id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        data.shopping[i].name = name.trimmingCharacters(in: .whitespaces)
        queue(.shop(data.shopping[i], deleted: false))
    }

    public func remove(_ item: ShopItem) {
        data.shopping.removeAll { $0.id == item.id }
        queue(.shop(item, deleted: true))
    }

    public func clearBought() {
        let bought = data.shopping.filter(\.done)
        data.shopping.removeAll(where: \.done)
        bought.forEach { queue(.shop($0, deleted: true), sync: false) }
        changed()
    }

    private func queue(_ p: Pending, sync: Bool = true) {
        data.outbox.removeAll { $0.key == p.key }
        data.outbox.append(p)
        if sync { changed() }
    }

    /// Save now, push soon (changes made within a second go together).
    private func changed() {
        persist()
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func persist() {
        guard file.path != "/dev/null", let d = try? JSONEncoder.iso.encode(data) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
    }

    /// Picks up changes another process (the MCP server, say) saved to the file.
    public func reloadFromDisk() {
        guard let d = try? JSONDecoder.iso.decode(HomeData.self, from: Data(contentsOf: file)) else { return }
        data = d
    }

    // MARK: Account & household

    public func sendSignInLink(email: String) async throws { try await supabase.sendSignInLink(email: email) }

    public func finishSignIn(_ url: URL) async throws {
        try await supabase.finishSignIn(url)
        await signedInFresh()
    }

    public func signIn(email: String, password: String) async throws {
        try await supabase.signIn(email: email, password: password)
        await signedInFresh()
    }

    public func setPassword(_ password: String) async throws { try await supabase.setPassword(password) }

    private func signedInFresh() async {
        data = HomeData()
        persist()
        await sync()
    }

    public func signOut() {
        supabase.signOut()
        data = HomeData()
        needsHousehold = false
        persist()
    }

    public func createHousehold(myName: String) async throws {
        _ = try await supabase.rpc("join_or_create_household", ["member_name": myName.trimmingCharacters(in: .whitespaces)])
        await sync()
    }

    public func joinHousehold(code: String, myName: String) async throws {
        do {
            _ = try await supabase.rpc("join_household", ["code": code, "member_name": myName.trimmingCharacters(in: .whitespaces)])
        } catch let e as SupabaseError where e.message.contains("invalid invite code") {
            throw SupabaseError(status: 400, message: "Tento kód nepoznám. Skontroluj ho v Domácnosti na druhom Macu.")
        }
        data = HomeData()
        await sync()
    }

    public func renameHousehold(_ name: String) async throws {
        guard let h = data.household, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var c = URLComponents(url: supabase.url.appendingPathComponent("rest/v1/households"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "id", value: "eq.\(h.id)")]
        try await supabase.send("PATCH", c.url!, body: ["name": name.trimmingCharacters(in: .whitespaces)])
        await sync()
    }

    // MARK: Sync

    public func sync() async {
        guard supabase.signedIn, !syncing else { return }
        syncing = true; busy = true
        defer { syncing = false; busy = false; persist() }
        do {
            try await refreshHousehold()
            guard let hh = data.household?.id else { error = nil; return }
            try await push(hh)
            try await pull(hh)
            lastSync = .now
            error = nil
        } catch let e as SupabaseError where e.status == 401 {
            error = e.message
            if !supabase.signedIn { data = HomeData(); needsHousehold = false }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refreshHousehold() async throws {
        let o = try await supabase.rpc("my_household") as? [String: Any]
        guard let o, let id = o["id"] as? String else {
            needsHousehold = true
            if data.household != nil { data = HomeData() }
            return
        }
        needsHousehold = false
        let members = (o["members"] as? [[String: Any]] ?? []).compactMap { m -> Member? in
            guard let u = m["user_id"] as? String, let n = m["name"] as? String else { return nil }
            return Member(userId: u, name: n)
        }
        let info = HouseholdInfo(id: id, name: o["name"] as? String ?? "Domov", inviteCode: o["invite_code"] as? String ?? "", members: members)
        if let old = data.household, old.id != id { data = HomeData() }
        data.household = info
    }

    private func push(_ hh: String) async throws {
        let batch = data.outbox
        guard !batch.isEmpty else { return }
        var tasks: [[String: Any]] = [], done: [[String: Any]] = [], shop: [[String: Any]] = []
        for p in batch {
            switch p {
            case let .task(t, deleted):
                let rule = (try? JSONSerialization.jsonObject(with: JSONEncoder.iso.encode(t.repeatRule))) ?? [:]
                tasks.append(["household_id": hh, "id": t.id, "title": t.title, "who": t.who, "part": t.part.rawValue,
                              "repeat": rule, "deleted": deleted])
            case .completion(let c):
                done.append(["household_id": hh, "task_id": c.taskId, "period": c.day.description, "done": c.done,
                             "done_by": c.by ?? NSNull()])
            case let .shop(s, deleted):
                shop.append(["household_id": hh, "id": s.id, "name": s.name, "done": s.done, "deleted": deleted])
            }
        }
        try await supabase.upsert("tasks", tasks, onConflict: "household_id,id")
        try await supabase.upsert("task_completions", done, onConflict: "household_id,task_id,period")
        try await supabase.upsert("shopping_items", shop, onConflict: "household_id,id")
        // Only what was sent; anything changed meanwhile stays queued.
        data.outbox.removeAll { batch.contains($0) }
    }

    private func pull(_ hh: String) async throws {
        let queued = Set(data.outbox.map(\.key))
        for table in ["tasks", "task_completions", "shopping_items"] {
            let rows = try await supabase.changed(table, household: hh, since: data.pulled[table])
            for r in rows {
                switch table {
                case "tasks":
                    guard let id = r["id"] as? String, !queued.contains("task:\(id)") else { continue }
                    if r["deleted"] as? Bool == true { data.tasks.removeAll { $0.id == id }; continue }
                    guard let ruleObj = r["repeat"], let ruleData = try? JSONSerialization.data(withJSONObject: ruleObj),
                          let rule = try? JSONDecoder.iso.decode(Repeat.self, from: ruleData) else { continue }
                    let t = HomeTask(id: id, title: r["title"] as? String ?? "", who: r["who"] as? String ?? Who.anyone,
                                     part: DayPart(rawValue: r["part"] as? String ?? "") ?? .anytime, repeatRule: rule)
                    if let i = data.tasks.firstIndex(where: { $0.id == id }) { data.tasks[i] = t } else { data.tasks.append(t) }
                case "task_completions":
                    guard let tid = r["task_id"] as? String, let day = Day(r["period"] as? String ?? "") else { continue }
                    let c = Completion(taskId: tid, day: day, done: r["done"] as? Bool ?? true, by: r["done_by"] as? String)
                    guard !queued.contains("done:\(c.key)") else { continue }
                    data.completions[c.key] = c.done ? c : nil
                default:
                    guard let id = r["id"] as? String, !queued.contains("shop:\(id)") else { continue }
                    if r["deleted"] as? Bool == true { data.shopping.removeAll { $0.id == id }; continue }
                    let s = ShopItem(id: id, name: r["name"] as? String ?? "", done: r["done"] as? Bool ?? false)
                    if let i = data.shopping.firstIndex(where: { $0.id == id }) { data.shopping[i] = s } else { data.shopping.append(s) }
                }
                if let u = r["updated_at"] as? String { data.pulled[table] = u }
            }
        }
    }
}
