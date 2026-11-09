import Foundation
import SwiftUI

/// Loads meetings from Brain (`node ~/Developer/brain/src/cli.js meetings`) and keeps the last result on disk, so the window
/// shows data right away while a fresh one loads. Meeting prep is loaded per event when it's opened, and kept for the session.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var data: MeetingsData?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var preps: [String: Prep] = [:]
    @Published private(set) var prepErrors: [String: String] = [:]
    @Published private(set) var prepLoading: Set<String> = []
    /// A recording being moved or deleted (its path), and what went wrong with the last such action.
    @Published private(set) var busy: Set<String> = []
    @Published var actionError: String?
    /// Set by a URL (meetings://next) for the window to select.
    @Published var pendingSelection: String?

    nonisolated static let brainDir = NSHomeDirectory() + "/Developer/brain"
    nonisolated static let node = ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/node"

    var openMain: (() -> Void)?
    private var generation = 0

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Meetings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meetings.json")
    }

    init() { data = (try? Data(contentsOf: cacheURL)).flatMap { try? MeetingsData.decode($0) } }

    func refresh() {
        generation += 1
        let gen = generation, cache = cacheURL
        loading = true
        error = nil
        Task {
            let result = await Task.detached { Self.run(["meetings", "--days", "365"]) }.value
            guard gen == generation else { return }
            loading = false
            switch result {
            case .success(let d):
                do { data = try MeetingsData.decode(d); try? d.write(to: cache, options: .atomic) }
                catch { self.error = "Brain vrátil dáta, ktorým appka nerozumie (\(error.localizedDescription))." }
            case .failure(let e): error = e.message
            }
        }
    }

    func loadPrep(_ id: String, force: Bool = false) {
        guard force || (preps[id] == nil && !prepLoading.contains(id)) else { return }
        prepLoading.insert(id)
        prepErrors[id] = nil
        Task {
            let result = await Task.detached { Self.run(["meeting-prep", id]) }.value
            prepLoading.remove(id)
            switch result {
            case .success(let d):
                do { preps[id] = try Prep.decode(d) } catch { prepErrors[id] = "Prípravu sa nepodarilo prečítať (\(error.localizedDescription))." }
            case .failure(let e): prepErrors[id] = e.message
            }
        }
    }

    /// Moves a recording's note to another business's folder (`brain meeting-move`); returns its new path.
    func move(_ r: Recording, to b: Business) async -> String? {
        struct Moved: Decodable { let path: String }
        guard let d = await act(r, ["meeting-move", r.path, b.rawValue]) else { return nil }
        guard let m = try? JSONDecoder().decode(Moved.self, from: d) else { actionError = "Brain nepovedal, kam nahrávku presunul."; return nil }
        update { recs in
            if let i = recs.firstIndex(where: { $0.path == r.path }) { recs[i].path = m.path; recs[i].business = b.rawValue }
        }
        return m.path
    }

    /// Puts a recording's note in the Trash (`brain meeting-delete`); Finder can put it back.
    func delete(_ r: Recording) async -> Bool {
        guard await act(r, ["meeting-delete", r.path]) != nil else { return false }
        update { $0.removeAll { $0.path == r.path } }
        return true
    }

    private func act(_ r: Recording, _ args: [String]) async -> Data? {
        busy.insert(r.path)
        actionError = nil
        let result = await Task.detached { Self.run(args) }.value
        busy.remove(r.path)
        switch result {
        case .success(let d): return d
        case .failure(let e): actionError = e.message; return nil
        }
    }

    /// Changes the recordings right away (and in the cache), without waiting for a full refresh.
    private func update(_ change: (inout [Recording]) -> Void) {
        guard var d = data else { return }
        change(&d.recordings)
        data = d
        if let bytes = try? d.encoded() { try? bytes.write(to: cacheURL, options: .atomic) }
    }

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
