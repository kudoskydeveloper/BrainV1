import AppKit
import Foundation
import SwiftUI

// MARK: model (the CLI's JSON)

struct Overview: Codable {
    var companies: [CompanyRow]
    var people: [Person]
    var blocked: [String]
    var lists: [ListRow]?
    var totals: Totals?
    struct Totals: Codable { var orgs: Int; var sites: Int; var people: Int }
}

struct ListRow: Codable, Hashable, Identifiable { var name: String; var members: Int; var id: String { name } }

struct CompanyRow: Codable, Identifiable, Hashable {
    var domain: String
    var crawledAt: String
    var mx: Bool
    var pattern: String?
    var emails: Int
    var people: Int
    var id: String { domain }
}

struct Person: Codable, Identifiable, Hashable {
    var pid: String?
    var name: String
    var domain: String?             // registry people (konatelia) have none until their company's web is read
    var title: String?
    var role: String?
    var company: String?
    var origin: String?
    var email: String?
    var confidence: String?
    var pattern: String?
    var at: String?
    var alternatives: [String]?
    var blocked: Bool?
    var generic: [String]?
    var why: String?
    var id: String { pid ?? "\(name)@\(domain ?? "")" }
    enum CodingKeys: String, CodingKey {
        case pid = "id", name, domain, title, role, company, origin, email, confidence, pattern, at, alternatives, blocked, generic, why
    }
}

struct Company: Codable, Hashable {
    var domain: String
    var crawledAt: String
    var mx: Bool
    var pattern: String?
    var patternExamples: [Example]
    var pagesRead: Int
    var skippedByRobots: Int
    var emails: [Email]

    struct Example: Codable, Hashable { var email: String; var name: String; var pattern: String }
    struct Email: Codable, Hashable, Identifiable {
        var email: String
        var kind: String          // person | generic | other
        var name: String?
        var how: String?
        var url: String?
        var context: String?
        var foundAt: String?
        var own: Bool
        var blocked: Bool?
        var id: String { email }
    }
}

enum Confidence {
    static func label(_ c: String?) -> String {
        switch c {
        case "found": "nájdená na webe"
        case "pattern": "podľa vzoru firmy"
        case "mx": "len odhad (doména prijíma poštu)"
        default: c ?? ""
        }
    }
    static func tint(_ c: String?) -> Color { c == "found" ? .green : c == "pattern" ? .blue : .orange }
    static func pattern(_ p: String?) -> String {
        switch p {
        case "first.last": "meno.priezvisko@"
        case "firstlast": "menopriezvisko@"
        case "f.last": "m.priezvisko@"
        case "flast": "mpriezvisko@"
        case "first": "meno@"
        case "last": "priezvisko@"
        case "last.first": "priezvisko.meno@"
        case "lastf": "priezviskom@"
        case "first_last": "meno_priezvisko@"
        case "first-last": "meno-priezvisko@"
        default: p ?? "nezistený"
        }
    }
}

// MARK: store

/// Talks to the Scout CLI (`node ~/Developer/scout/src/cli.js`): the list, a company (reading its website takes a while),
/// a person, Nekontaktovať, delete on request. The list is cached so the window opens with it.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var data: Overview?
    @Published private(set) var companies: [String: Company] = [:]
    @Published var busy: String?
    @Published var error: String?
    @Published var toast: String?
    @Published var lastPerson: Person?
    /// Set by a URL (scout://company/firma.sk) for the window to select.
    @Published var pendingSelection: String?
    @Published var pendingQuery: [String: String] = [:]

    nonisolated static let cli = NSHomeDirectory() + "/Developer/scout/src/cli.js"
    nonisolated static let node = ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/node"
    var openMain: (() -> Void)?

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scout")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("list.json")
    }

    init() { data = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Overview.self, from: $0) } }

    func refresh() {
        let cache = cacheURL
        Task {
            if case .success(let d) = await Task.detached { Self.run(["list"]) }.value, let o = try? JSONDecoder().decode(Overview.self, from: d) {
                data = o
                try? d.write(to: cache, options: .atomic)
            }
        }
    }

    /// A company's addresses (cached by Scout for a month; `fresh` reads the website again).
    func company(_ domain: String, fresh: Bool = false, org: String? = nil, done: ((Company) -> Void)? = nil) {
        if !fresh, org == nil, let c = companies[domain] { done?(c); return }
        busy = fresh || data?.companies.contains(where: { $0.domain == domain }) != true ? "Čítam web \(domain)…" : nil
        Task {
            let r = await Task.detached { Self.run(["company", domain] + (fresh ? ["--fresh"] : []) + (org.map { ["--org=\($0)"] } ?? [])) }.value
            busy = nil
            switch r {
            case .success(let d):
                if let c = try? JSONDecoder().decode(Company.self, from: d) { companies[c.domain] = c; done?(c); refresh() }
                else { error = "Scout vrátil dáta, ktorým appka nerozumie." }
            case .failure(let e): error = e.message
            }
        }
    }

    func person(name: String, domain: String, done: ((Person) -> Void)? = nil) {
        busy = "Hľadám \(name) na \(domain)…"
        Task {
            let r = await Task.detached { Self.run(["person", name, domain]) }.value
            busy = nil
            switch r {
            case .success(let d):
                if let p = try? JSONDecoder().decode(Person.self, from: d) { lastPerson = p; done?(p); refresh(); company(domain) }
                else { error = "Scout vrátil dáta, ktorým appka nerozumie." }
            case .failure(let e): error = e.message
            }
        }
    }

    func block(_ target: String, undo: Bool = false) {
        Task {
            _ = await Task.detached { Self.run(["block", target] + (undo ? ["--undo"] : [])) }.value
            toast = undo ? "\(target) už nie je v Nekontaktovať" : "\(target) je v Nekontaktovať"
            companies = [:]
            refresh()
        }
    }

    func forget(_ target: String) {
        Task {
            _ = await Task.detached { Self.run(["forget", target]) }.value
            toast = "\(target) vymazané (a ostáva v Nekontaktovať)"
            companies = [:]
            refresh()
        }
    }

    struct RunError: Error { let message: String }

    nonisolated static func run(_ args: [String]) -> Result<Data, RunError> {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [cli] + args
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return .failure(RunError(message: "Scout sa nepodarilo spustiť (\(error.localizedDescription)).")) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            return .failure(RunError(message: e.split(separator: "\n").last { $0.contains("Error") }.map { String($0).replacingOccurrences(of: "Error: ", with: "") } ?? String(e.suffix(200))))
        }
        return .success(data)
    }
}

func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
