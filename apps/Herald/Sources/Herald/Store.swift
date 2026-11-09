import AppKit
import Foundation
import SwiftUI

/// Talks to the linkedin-mcp server on 127.0.0.1:47332 (`server/src/ui-server.js`). Reads need nothing; changes carry the
/// local secret (~/.herald/secret) in `x-herald-secret`. When nothing answers, the app starts the server itself
/// (`node server/src/daemon.js`), so Herald works without an open Claude session. The last state is cached on disk so the
/// window opens with data right away.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var state: AppState?
    /// Beeper couldn't be read (not running, Brain not signed in); the inbox then shows the older download.
    @Published private(set) var beeperError: String?
    private var base: AppState?
    private var inbox: BeeperInbox?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var actionError: String?
    @Published var toast: String?
    /// Long LinkedIn jobs (sync, search, invite, withdraw), shown in the toolbar: what runs now.
    @Published private(set) var busy: String?
    /// Set by a URL (herald://reply) for the window to select.
    @Published var pendingSelection: String?
    /// Found by the last people search, in LinkedIn's order.
    @Published var found: [String] = []

    nonisolated static let serverDir = NSHomeDirectory() + "/Developer/linkedin-mcp/server"
    nonisolated static let dataDir = ProcessInfo.processInfo.environment["LINKEDIN_MCP_DIR"] ?? NSHomeDirectory() + "/.herald"
    nonisolated static let node = ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/node"
    nonisolated static let base = URL(string: "http://127.0.0.1:47332/api")!

    var openMain: (() -> Void)?
    private var startedDaemon = false
    private var generation = 0

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Herald")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    init() {
        base = (try? Data(contentsOf: cacheURL)).flatMap { try? AppState.decode($0) }
        inbox = (try? Data(contentsOf: inboxCacheURL)).flatMap { try? JSONDecoder().decode(BeeperInbox.self, from: $0) }
        publish()
    }

    private var inboxCacheURL: URL { cacheURL.deletingLastPathComponent().appendingPathComponent("beeper-inbox.json") }

    /// The server's state with Beeper's live inbox over it.
    private func publish() {
        guard var s = base else { return }
        if let inbox { s.merge(inbox) }
        state = s
    }

    // MARK: reading

    private var polling = false
    private var lastRefresh = Date.distantPast

    /// Chrome's connection changes on its own (Chrome quits, the server restarts): check it every 15 s, and reload
    /// everything when the window comes forward after 2 minutes or more.
    private func startPolling() {
        guard !polling else { return }
        polling = true
        Task {
            while true {
                try? await Task.sleep(for: .seconds(15))
                guard case .success(let d) = await Self.get("status"),
                      let on = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["extensionConnected"] as? Bool,
                      var b = base, b.extensionConnected != on else { continue }
                b.extensionConnected = on
                base = b
                publish()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in if Date().timeIntervalSince(Store.shared.lastRefresh) > 120 { Store.shared.refresh() } }
        }
    }

    func refresh() {
        startPolling()
        lastRefresh = Date()
        refreshInbox()
        generation += 1
        let gen = generation, cache = cacheURL
        loading = true
        error = nil
        Task {
            var result = await Self.get("state")
            if case .failure = result, !startedDaemon {
                startDaemon()
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(500))
                    result = await Self.get("state")
                    if case .success = result { break }
                }
            }
            guard gen == generation else { return }
            loading = false
            switch result {
            case .success(let d):
                do { base = try AppState.decode(d); try? d.write(to: cache, options: .atomic); publish(); publishBadge() }
                catch { self.error = "Server vrátil dáta, ktorým appka nerozumie (\(error.localizedDescription))." }
            case .failure(let e): error = e.message
            }
        }
    }

    /// LinkedIn chats from Beeper through Brain (`brain linkedin-inbox`), like Ľudia reads its data.
    func refreshInbox() {
        let cache = inboxCacheURL
        Task {
            let result = await Task.detached { Self.brain(["linkedin-inbox"]) }.value
            switch result {
            case .success(let d):
                if let i = try? JSONDecoder().decode(BeeperInbox.self, from: d) {
                    inbox = i; beeperError = nil; try? d.write(to: cache, options: .atomic); publish(); publishBadge()
                } else { beeperError = "Brain vrátil z Beepera dáta, ktorým appka nerozumie." }
            case .failure(let e): beeperError = e.message
            }
        }
    }

    nonisolated static let brainDir = NSHomeDirectory() + "/Developer/brain"

    nonisolated static func brain(_ args: [String]) -> Result<Data, Failure> {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [brainDir + "/src/cli.js"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: brainDir)
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return .failure(.init(message: "Brain sa nepodarilo spustiť (\(error.localizedDescription)).")) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let line = e.split(separator: "\n").last { $0.contains("Error") || $0.contains("Beeper") }.map(String.init) ?? e.suffix(200).description
            return .failure(.init(message: line.replacingOccurrences(of: "Error: ", with: "")))
        }
        return .success(data)
    }

    /// The server isn't running.
    /// Normally launchd runs it from login (com.lockedin.herald-server, see linkedin-mcp/scripts/install-agent.sh): restart
    /// that; without the agent, start daemon.js detached.
    func startDaemon() {
        startedDaemon = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "launchctl kickstart -k gui/$(id -u)/com.lockedin.herald-server 2>/dev/null || nohup '\(Self.node)' '\(Self.serverDir)/src/daemon.js' >/dev/null 2>&1 &"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Hangar's tile badge: people waiting for your reply.
    func publishBadge() {
        let n = state.map { s in s.conversations.filter(s.needsReply).count } ?? 0, id = "com.lockedin.herald"
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.lockedin/badges")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(n)".write(to: dir.appendingPathComponent(id), atomically: true, encoding: .utf8)
        DistributedNotificationCenter.default().postNotificationName(.init("com.lockedin.badge"), object: id, userInfo: ["count": n], deliverImmediately: true)
    }

    // MARK: changes

    /// Local changes (stage, tags, note, projects): quick, and the window updates in place, then reloads.
    func setStage(ids: [String] = [], slugs: [String] = [], project: String, stage: String?) {
        post("stage", ["ids": ids, "slugs": slugs, "project": project, "stage": stage as Any]) { _ in self.refresh() }
    }

    /// Vybavené: dealt with, no reply needed; it comes back when they write again. undo puts it back now.
    func markDone(_ list: [Conversation], undo: Bool = false) {
        guard var b = base else { return }
        var done = b.inboxDone ?? [:]
        for c in list { if undo { done[c.doneKey] = nil } else { done[c.doneKey] = c.lastAtMs ?? Date().timeIntervalSince1970 * 1000 } }
        b.inboxDone = done
        base = b
        publish(); publishBadge()
        for c in list {
            var body: [String: Any] = ["key": c.doneKey, "undo": undo]
            if let at = c.lastAtMs { body["at"] = at }
            post("done", body) { _ in }
        }
        if !undo { toast = list.count == 1 ? "Vybavené: \(list[0].with)" : "Vybavených \(list.count)" }
    }

    func tag(_ ids: [String], add: [String] = [], remove: [String] = [], note: String? = nil) {
        var b: [String: Any] = ["ids": ids, "add": add, "remove": remove]
        if let note { b["note"] = note }
        post("tag", b) { _ in self.refresh() }
    }

    func saveProject(name: String, id: String? = nil, playbook: String?) {
        var b: [String: Any] = ["name": name]
        if let id { b["id"] = id }
        if let playbook, !playbook.isEmpty { b["playbook"] = playbook }
        post("project", b) { _ in self.refresh() }
    }

    /// LinkedIn jobs go through the extension in Chrome and can take minutes.
    func sync(_ what: SyncKind) {
        switch what {
        case .connections(let full): job("Sťahujem kontakty…", "sync", ["mode": full ? "full" : "new"]) { r in "Kontakty: \(r["added"] ?? 0) nových, spolu \(r["total"] ?? "?")." }
        case .invites: job("Načítavam pozvánky…", "sync-sent-invites", [:]) { r in "Čakajúce pozvánky: \(r["pending"] ?? 0)." }
        case .country(let c): job("Hľadám kontakty v krajine \(c)…", "sync-country", ["country": c]) { r in "\(c): \(r["matched"] ?? 0) kontaktov." }
        }
    }

    func findPeople(keywords: String, country: String?, degree: String, project: String?, page: Int) {
        job("Hľadám na LinkedIne…", "find-people", ["keywords": keywords, "country": country ?? "", "degree": degree, "project": project ?? "", "page": page]) { [weak self] r in
            let rows = (r["_rows"] as? [[String: Any]]) ?? []
            let slugs = rows.compactMap { $0["slug"] as? String }
            self?.found = page == 1 ? slugs : (self?.found ?? []) + slugs.filter { !(self?.found.contains($0) ?? false) }
            return rows.isEmpty ? "Nič sa nenašlo." : "Nájdených \(rows.count) ľudí."
        }
    }

    func invite(_ p: Prospect, note: String, project: String?) {
        job("Posielam pozvánku \(p.name)…", "invite", ["slug": p.slug, "name": p.name, "note": note, "project": project ?? ""]) { r in
            (r["verified"] as? Bool) == false ? "Pozvánka odoslaná, ale LinkedIn ju nepotvrdil. Skontroluj profil." : "Pozvánka pre \(p.name) odoslaná."
        }
    }

    func withdraw(_ ids: [String]) {
        job("Sťahujem \(ids.count) pozvánok…", "withdraw", ["ids": ids]) { r in
            if let e = r["error"] as? String { return "Stiahnutých \(r["withdrawn"] ?? 0), zastavené pri \(r["stoppedAt"] ?? "?"): \(e)" }
            return "Stiahnutých \(r["withdrawn"] ?? 0) pozvánok."
        }
    }

    enum SyncKind { case connections(full: Bool), invites, country(String) }

    private func job(_ label: String, _ path: String, _ body: [String: Any], done: @escaping ([String: Any]) -> String) {
        guard busy == nil else { actionError = "Už beží: \(busy!)"; return }
        busy = label
        post(path, body, timeout: 3600) { [weak self] json in
            self?.busy = nil
            var r = (json as? [String: Any]) ?? [:]
            if let rows = json as? [[String: Any]] { r = ["_rows": rows] }
            self?.toast = done(r)
            self?.refresh()
        } failed: { [weak self] in self?.busy = nil }
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 30, done: @escaping (Any) -> Void,
                      failed: @escaping () -> Void = {}) {
        Task {
            switch await Self.send(path, body, timeout: timeout) {
            case .success(let d): done((try? JSONSerialization.jsonObject(with: d)) ?? [:])
            case .failure(let e): actionError = e.message; failed()
            }
        }
    }

    // MARK: HTTP

    struct Failure: Error { let message: String }

    nonisolated static var secret: String {
        (try? String(contentsOfFile: dataDir + "/secret", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func get(_ path: String) async -> Result<Data, Failure> {
        await request(URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20))
    }

    nonisolated static func send(_ path: String, _ body: [String: Any], timeout: TimeInterval) async -> Result<Data, Failure> {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(secret, forHTTPHeaderField: "x-herald-secret")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await request(r)
    }

    nonisolated private static func request(_ r: URLRequest) async -> Result<Data, Failure> {
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return .success(d) }
            if code == 403 { return .failure(.init(message: "Server odmietol zmenu (chýba alebo nesedí ~/.herald/secret).")) }
            let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            return .failure(.init(message: msg ?? "Server odpovedal chybou \(code)."))
        } catch {
            return .failure(.init(message: "LinkedIn server na 127.0.0.1:47332 neodpovedá. Spusti ho: node ~/Developer/linkedin-mcp/server/src/daemon.js"))
        }
    }
}
