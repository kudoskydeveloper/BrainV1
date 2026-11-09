import Foundation
import SwiftUI

/// Loads the overview from Brain (`node ~/Developer/brain/src/cli.js fitness --days N`) and keeps the last one per period on disk,
/// so the window shows data right away on the next launch while a fresh one loads.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var overview: Overview?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var days: Int = UserDefaults.standard.object(forKey: "days") as? Int ?? 30 {
        didSet {
            guard days != oldValue else { return }
            UserDefaults.standard.set(days, forKey: "days")
            refresh()
        }
    }

    nonisolated static let brainDir = NSHomeDirectory() + "/Developer/brain"
    nonisolated static let node = ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/node"

    /// Reopens the window after it was closed (set from the window's `openWindow`, which outlives the window).
    var openMain: (() -> Void)?
    private var generation = 0

    private func cacheURL(_ days: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fitness")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("overview-\(days).json")
    }

    private func cached(_ days: Int) -> Overview? { (try? Data(contentsOf: cacheURL(days))).flatMap { try? Overview.decode($0) } }

    init() { overview = cached(days) }

    func refresh() {
        generation += 1
        let gen = generation, days = days, cache = cacheURL(days)
        if overview.map({ Int($0.period.days) != days }) ?? true { overview = cached(days) }   // other period: its last data meanwhile
        loading = true
        error = nil
        Task {
            let result = await Task.detached { Self.run(days: days) }.value
            guard gen == generation else { return }   // a newer refresh (other period) is on its way
            loading = false
            switch result {
            case .success(let data):
                do {
                    overview = try Overview.decode(data)
                    try? data.write(to: cache, options: .atomic)
                } catch {
                    self.error = "Brain vrátil dáta, ktorým appka nerozumie (\(error.localizedDescription))."
                }
            case .failure(let e):
                error = e.message
            }
        }
    }

    struct RunError: Error { let message: String }

    nonisolated static func run(days: Int) -> Result<Data, RunError> {
        let cli = brainDir + "/src/cli.js"
        guard FileManager.default.fileExists(atPath: cli) else { return .failure(RunError(message: "Brain sa nenašiel v \(cli).")) }
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [cli, "fitness", "--days", String(days)]
        p.currentDirectoryURL = URL(fileURLWithPath: brainDir)
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(RunError(message: "Nepodarilo sa spustiť Node (\(node)): \(error.localizedDescription)")) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
        // both pipes read at once: a full stderr pipe would otherwise block the process while we wait on stdout
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
