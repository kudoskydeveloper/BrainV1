import AppKit
import Foundation
import SwiftUI

/// Loads both CRMs from Brain (`brain crm`) and keeps the last result on disk, so the window opens with data right away.
/// An account's detail (`brain crm-account`) is loaded when it opens. Read only for now (phase 1).
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var data: Overview?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var details: [String: AccountDetail] = [:]
    @Published private(set) var detailErrors: [String: String] = [:]
    @Published private(set) var detailLoading: Set<String> = []
    /// Set by a URL (obchody://today) for the window to select.
    @Published var pendingSelection: String?

    nonisolated static let brainDir = NSHomeDirectory() + "/Developer/brain"
    nonisolated static let node = ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/node"

    var openMain: (() -> Void)?
    private var generation = 0
    private var lastRefresh = Date.distantPast
    private var observing = false

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Obchody")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("crm.json")
    }

    init() { data = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Overview.self, from: $0) } }

    func refresh() {
        if !observing {
            observing = true
            // back to the window after 2 minutes or more: fresh data
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in if Date().timeIntervalSince(Store.shared.lastRefresh) > 120 { Store.shared.refresh() } }
            }
        }
        lastRefresh = Date()
        generation += 1
        let gen = generation, cache = cacheURL
        loading = true
        error = nil
        Task {
            let result = await Task.detached { Self.run(["crm"]) }.value
            guard gen == generation else { return }
            loading = false
            switch result {
            case .success(let d):
                do { data = try JSONDecoder().decode(Overview.self, from: d); try? d.write(to: cache, options: .atomic); details = [:]; publishBadge() }
                catch { self.error = "Brain vrátil dáta, ktorým appka nerozumie (\(error.localizedDescription))." }
            case .failure(let e): error = e.message
            }
        }
    }

    func loadDetail(_ business: String, _ account: String, force: Bool = false) {
        let key = "\(business)|\(account)"
        guard force || (details[key] == nil && !detailLoading.contains(key)) else { return }
        detailLoading.insert(key)
        detailErrors[key] = nil
        Task {
            let result = await Task.detached { Self.run(["crm-account", business, account]) }.value
            detailLoading.remove(key)
            switch result {
            case .success(let d):
                do { details[key] = try JSONDecoder().decode(AccountDetail.self, from: d) }
                catch { detailErrors[key] = "Detail sa nedá prečítať (\(error.localizedDescription))." }
            case .failure(let e): detailErrors[key] = e.message
            }
        }
    }

    func detail(_ business: String, _ account: String) -> AccountDetail? { details["\(business)|\(account)"] }

    // MARK: writes (phase 2)

    @Published var actionError: String?
    @Published var toast: String?
    @Published private(set) var saving = false

    /// Your click in the app: Brain translates the action to the CRM's own tool (`brain crm-do`). `optimistic` changes the
    /// board right away and is undone if the CRM refuses. Afterwards both CRMs and the open detail reload.
    func act(_ business: String, _ action: String, _ args: [String: Any], done: String? = nil, reload account: String? = nil,
             optimistic: ((inout Overview) -> Void)? = nil) {
        let before = data
        if let optimistic, var d = data { optimistic(&d); data = d }
        saving = true
        let json = String(data: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        Task {
            let result = await Task.detached { Self.run(["crm-do", business, action, json]) }.value
            saving = false
            switch result {
            case .success:
                if let done { toast = done }
                refresh()
                if let account { loadDetail(business, account, force: true) }
            case .failure(let e):
                data = before
                actionError = e.message
            }
        }
    }

    /// Hangar's tile badge: tasks past due in both CRMs.
    func publishBadge() {
        let today = Calendar.current.startOfDay(for: .now)
        let n = data?.businesses.flatMap(\.tasks).filter { t in t.due.flatMap(Fmt.day).map { $0 < today } ?? false }.count ?? 0
        let id = "com.lockedin.obchody"
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
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return .failure(RunError(message: "Brain sa nepodarilo spustiť (\(error.localizedDescription)).")) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let line = e.split(separator: "\n").last { $0.contains("Error") }.map(String.init) ?? String(e.suffix(200))
            return .failure(RunError(message: line.replacingOccurrences(of: "Error: ", with: "")))
        }
        return .success(data)
    }
}

/// Opens a mail in Courier (courier://message/<id>).
func openInCourier(_ id: Int?) { if let id, let u = URL(string: "courier://message/\(id)") { NSWorkspace.shared.open(u) } }

// MARK: Scout (phase 4): a contact's e-mail from the client's website

struct ScoutHit: Decodable, Hashable {
    var email: String?
    var confidence: String?
    var pattern: String?
    var alternatives: [String]?
    var blocked: Bool?
    var why: String?

    var label: String {
        switch confidence {
        case "found": "nájdená na webe"
        case "pattern": "podľa vzoru firmy"
        case "mx": "len odhad"
        default: ""
        }
    }
    var tint: Color { confidence == "found" ? .green : confidence == "pattern" ? .blue : .orange }
}

enum Scout {
    nonisolated static let cli = NSHomeDirectory() + "/Developer/scout/src/cli.js"

    /// `scout person "<name>" <domain>`: reads the client's website (cached a month) and returns the address with how sure it is.
    static func find(name: String, domain: String) async -> Result<ScoutHit, Store.RunError> {
        await Task.detached { () -> Result<ScoutHit, Store.RunError> in
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: Store.node)
            p.arguments = [cli, "person", name, domain]
            p.standardOutput = out; p.standardError = err
            do { try p.run() } catch { return .failure(.init(message: "Scout sa nepodarilo spustiť.")) }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let hit = try? JSONDecoder().decode(ScoutHit.self, from: d) else { return .failure(.init(message: "Scout nenašiel adresu.")) }
            return .success(hit)
        }.value
    }

    static func open(company domain: String) { if let u = URL(string: "scout://company/\(domain)") { NSWorkspace.shared.open(u) } }
}
