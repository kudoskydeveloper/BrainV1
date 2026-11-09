import Foundation
import SwiftUI

/// Loads people from Brain (`node ~/Developer/brain/src/cli.js ludia`) and keeps the last result on disk, so the window
/// shows data right away while a fresh one loads. A person's detail (`ludia-person`) is loaded when it's opened.
/// Changes (follow, note, promises, hide, settings) go to Brain right away (`ludia-set`, `ludia-sources`).
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var data: Overview?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var details: [String: Detail] = [:]
    @Published private(set) var detailErrors: [String: String] = [:]
    @Published private(set) var detailLoading: Set<String> = []
    @Published var actionError: String?
    /// Set by a URL (ludia://due) for the window to select.
    @Published var pendingSelection: String?
    /// A person to select once the list is reloaded (after a merge or split their id can change).
    @Published var pendingPerson: String?
    @Published private(set) var merging = false
    /// Topic search (who you talked with about it); empty when the search field is.
    @Published private(set) var topic: TopicResult?
    @Published private(set) var topicLoading = false
    private var topicTask: Task<Void, Never>?

    nonisolated static let brainDir = NSHomeDirectory() + "/Developer/brain"
    nonisolated static let node = ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/node"

    var openMain: (() -> Void)?
    private var generation = 0

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ludia")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ludia.json")
    }

    init() { data = (try? Data(contentsOf: cacheURL)).flatMap { try? Overview.decode($0) } }

    func refresh() {
        generation += 1
        let gen = generation, cache = cacheURL
        loading = true
        error = nil
        Task {
            let result = await Task.detached { Self.run(["ludia"]) }.value
            guard gen == generation else { return }
            loading = false
            switch result {
            case .success(let d):
                do { data = try Overview.decode(d); try? d.write(to: cache, options: .atomic); details = [:]; publishBadge() }
                catch { self.error = "Brain vrátil dáta, ktorým appka nerozumie (\(error.localizedDescription))." }
            case .failure(let e): error = e.message
            }
        }
    }

    func loadDetail(_ id: String, force: Bool = false) {
        guard force || (details[id] == nil && !detailLoading.contains(id)) else { return }
        detailLoading.insert(id)
        detailErrors[id] = nil
        Task {
            let result = await Task.detached { Self.run(["ludia-person", id]) }.value
            detailLoading.remove(id)
            switch result {
            case .success(let d):
                do {
                    let det = try Detail.decode(d)
                    if let e = det.error { detailErrors[id] = e } else {
                        details[id] = det
                        // the detail reads Brain's own data, so what you keep about the person wins over the cached list
                        let open = (det.promises ?? []).filter { !$0.done }.count
                        update(id) { x in
                            x.promisesOpen = open
                            if let p = det.person { x.follow = p.follow; x.every = p.every; x.note = p.note }
                            x.due = x.isOverdue
                        }
                    }
                } catch { detailErrors[id] = "Detail sa nepodarilo prečítať (\(error.localizedDescription))." }
            case .failure(let e): detailErrors[id] = e.message
            }
        }
    }

    // MARK: changes

    struct Patch: Encodable {
        var follow: Bool?
        var every: Int?
        var note: String?
        var business: String?
        var hidden: Bool?
        var name: String?
        var promise: String?
        var due: String?
        var promiseDone: String?
        var promiseUndo: String?
        var promiseDelete: String?
        var birthday: String?
        var birthdayName: String?
    }

    /// Saves a change about a person in Brain and shows it here right away.
    func set(_ p: Person, _ patch: Patch) {
        update(p.id) { x in
            if let f = patch.follow { x.follow = f }
            if let e = patch.every { x.every = e }
            if let n = patch.note { x.note = n }
            if let b = patch.business { x.business = b; x.businessGuessed = false }
            if let n = patch.name, !n.isEmpty { x.name = n }
            x.due = x.isOverdue
        }
        if patch.hidden == true, var d = data {
            d.people.removeAll { $0.id == p.id }
            d.due.removeAll { $0 == p.id }
            d.fading.removeAll { $0 == p.id }
            save(d)
        }
        let json = (try? JSONEncoder.snake.encode(patch)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let touchesPromises = patch.promise != nil || patch.promiseDone != nil || patch.promiseUndo != nil || patch.promiseDelete != nil
        Task {
            let result = await Task.detached { Self.run(["ludia-set", p.id, json]) }.value
            switch result {
            case .success(let d):
                struct Done: Decodable { struct State: Decodable { var promises: [Promise]? }; var error: String?; var state: State? }
                let done = try? JSONDecoder.snake.decode(Done.self, from: d)
                if let e = done?.error { actionError = e; return }
                if let promises = done?.state?.promises {
                    details[p.id]?.promises = promises
                    update(p.id) { $0.promisesOpen = promises.filter { !$0.done }.count }
                }
                if touchesPromises && details[p.id] == nil { loadDetail(p.id) }
                if patch.birthday != nil { pendingPerson = p.id; refresh() }
            case .failure(let e): actionError = "Zmenu sa nepodarilo uložiť: \(e.message)"
            }
        }
    }

    /// `other` is the same person as `p` (a duplicate): Brain links the two for good and rebuilds the list.
    /// `keepName` is the name the merged person keeps.
    func merge(_ p: Person, with other: Person, keepName: String) {
        merging = true
        Task {
            let r = await Task.detached { Self.run(["ludia-merge", p.id, other.id]) }.value
            await finishMerge(r, name: keepName == p.name ? nil : keepName)
        }
    }

    /// Undoes every merge of this person.
    func split(_ p: Person) {
        merging = true
        Task { await finishMerge(await Task.detached { Self.run(["ludia-split", p.id]) }.value, name: nil) }
    }

    private func finishMerge(_ r: Result<Data, RunError>, name: String?) async {
        struct Done: Decodable { var ok: Bool?; var id: String?; var error: String? }
        defer { merging = false }
        switch r {
        case .failure(let e): actionError = e.message; return
        case .success(let d):
            guard let done = try? JSONDecoder().decode(Done.self, from: d), done.ok == true, let id = done.id else {
                actionError = (try? JSONDecoder().decode(Done.self, from: d))?.error ?? "Zlúčenie sa nepodarilo."; return
            }
            if let name {
                let json = (try? JSONEncoder.snake.encode(Patch(name: name))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                _ = await Task.detached { Self.run(["ludia-set", id, json]) }.value
            }
            pendingPerson = id
            refresh()
        }
    }

    /// Sources and intervals (Nastavenia); a refresh follows, since they change who is in the list.
    /// `crm`: .some(nil) turns the work CRM off.
    func setSettings(sources: [String: String]? = nil, everyDays: Int? = nil, fadingDays: Int? = nil, crm: Overview.Crm?? = nil) {
        var patch: [String: Any] = sources ?? [:]
        if let c = crm {
            patch["crm"] = c.map { ["label": $0.label, "server": $0.server, "tool": $0.tool, "args": $0.args, "groups": $0.groups] } ?? NSNull()
        }
        if let e = everyDays { patch["every_days"] = e }
        if let f = fadingDays { patch["fading_days"] = f }
        if var d = data {
            if let s = sources { d.settings.sources.merge(s) { $1 } }
            if let e = everyDays { d.settings.everyDays = e }
            if let f = fadingDays { d.settings.fadingDays = f }
            if let c = crm { d.settings.crm = c }
            data = d
        }
        let json = (try? JSONSerialization.data(withJSONObject: patch)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        Task {
            switch await Task.detached(operation: { Self.run(["ludia-sources", json]) }).value {
            case .success: refresh()
            case .failure(let e): actionError = "Nastavenia sa nepodarilo uložiť: \(e.message)"
            }
        }
    }

    /// Searches what was said (mail, WhatsApp, Beeper, meeting titles) a moment after typing stops.
    func searchTopic(_ q: String) {
        topicTask?.cancel()
        let q = q.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { topic = nil; topicLoading = false; return }
        topicLoading = true
        topicTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let r = await Task.detached { Self.run(["ludia-search", q]) }.value
            guard !Task.isCancelled else { return }
            topicLoading = false
            if case .success(let d) = r { topic = try? JSONDecoder.snake.decode(TopicResult.self, from: d) } else { topic = nil }
        }
    }

    /// A birthday from a calendar ("Rudi") belongs to this person: Brain remembers the name and matches it from now on.
    func assignBirthday(_ who: String, to p: Person) {
        let json = (try? JSONEncoder.snake.encode(Patch(birthdayName: who))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        Task {
            switch await Task.detached(operation: { Self.run(["ludia-set", p.id, json]) }).value {
            case .success: pendingPerson = p.id; refresh()
            case .failure(let e): actionError = "Narodeniny sa nepodarilo priradiť: \(e.message)"
            }
        }
    }

    /// Read tools of every MCP server Brain knows (for the CRM picker).
    func crmServers() async -> [CrmServer] {
        guard case .success(let d) = await Task.detached(operation: { Self.run(["ludia-crm-tools"]) }).value else { return [] }
        return (try? JSONDecoder().decode([CrmServer].self, from: d)) ?? []
    }

    private func update(_ id: String, _ change: (inout Person) -> Void) {
        guard var d = data, let i = d.people.firstIndex(where: { $0.id == id }) else { return }
        change(&d.people[i])
        d.due = d.people.filter(\.due).sorted { ($0.days ?? .max) > ($1.days ?? .max) }.map(\.id)
        if d.people[i].follow { d.fading.removeAll { $0 == id } }
        if var det = details[id] { det.person = d.people[i]; details[id] = det }
        save(d)
    }

    private func save(_ d: Overview) {
        data = d
        if let bytes = try? d.encoded() { try? bytes.write(to: cacheURL, options: .atomic) }
        publishBadge()
    }

    /// The number of people waiting in "Ozvi sa" as the red badge on Hangar's tile: a file Hangar reads at start and a
    /// distributed notification for the change (the same way Courier shows unread mail).
    private func publishBadge() {
        let n = data?.due.count ?? 0, id = "com.lockedin.ludia"
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.lockedin/badges")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(n)".write(to: dir.appendingPathComponent(id), atomically: true, encoding: .utf8)
        DistributedNotificationCenter.default().postNotificationName(.init("com.lockedin.badge"), object: id, userInfo: ["count": n], deliverImmediately: true)
    }

    // MARK: Brain

    struct RunError: Error { let message: String }

    nonisolated static func run(_ args: [String]) -> Result<Data, RunError> {
        let cli = brainDir + "/src/cli.js"
        guard FileManager.default.fileExists(atPath: cli) else { return .failure(RunError(message: "Brain sa nenašiel v \(cli).")) }
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [cli] + args
        p.currentDirectoryURL = URL(fileURLWithPath: brainDir)
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(RunError(message: "Nepodarilo sa spustiť Node (\(node)): \(error.localizedDescription)")) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0, !data.isEmpty else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let line = msg.split(separator: "\n").last { $0.contains("Error") }.map(String.init) ?? String(msg.suffix(300))
            return .failure(RunError(message: line.isEmpty ? "Brain skončil s chybou (\(p.terminationStatus))." : line))
        }
        return .success(data)
    }
}
