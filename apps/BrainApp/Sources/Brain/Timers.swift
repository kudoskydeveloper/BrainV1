import AppKit
import Foundation
import UserNotifications

/// Follow-ups: "in an hour, check my positions", or "every 15 min until 18:00". Each runs at its time in a conversation of its
/// own in the history (never mixing into what is open in the panel) and notifies with the answer. A recurring one always has
/// an end (at most 7 days, 200 runs): nothing runs forever. Kept in timers.json, so they
/// survive restarts; one missed while the Mac slept or Brain was closed runs as soon as Brain is back.
@MainActor
final class TimerStore: ObservableObject {
    struct Job: Codable, Identifiable, Equatable {
        var id = UUID()
        let prompt: String
        let at: Date
        /// The conversation it was set from, mentioned to Claude so the answer has its context.
        var from: String?
        /// The user said to just do it: the timer carries the action out (confirms its own proposal), trades excepted.
        var approved: Bool? = false
        /// Recurring: run again every `every` seconds until `until` (both or neither).
        var every: TimeInterval?
        var until: Date?
        var runs: Int? = 0
        /// Only a reminder: the notification shows the prompt as written, nothing runs (no tokens).
        var remind: Bool? = false
        /// The app it should use (slug from the /app picker), e.g. "courier".
        var app: String?
    }

    static let shared = TimerStore()
    static let file = HistoryStore.dir.deletingLastPathComponent().appendingPathComponent("timers.json")
    @Published var jobs: [Job] = []
    private var timer: Timer?
    /// Conversations running a fired timer (kept alive until they finish).
    private var running: [UUID: Session] = [:]
    /// Called with (chat id, answer, failed) when a timer's answer is in; the app notifies and can open that chat.
    var onAnswer: ((UUID, String, Bool) -> Void)?
    /// Called with a reminder's job when it is due (just a notification).
    var onRemind: ((Job) -> Void)?

    init() {
        jobs = (try? JSONDecoder.iso.decode([Job].self, from: Data(contentsOf: Self.file))) ?? []
        // older timers from Brain's schedule tool came with "+" for every space: repair them once
        jobs = jobs.map { j in
            guard !j.prompt.contains(" "), j.prompt.contains("+") else { return j }
            return Job(id: j.id, prompt: j.prompt.replacingOccurrences(of: "+", with: " "), at: j.at, from: j.from, approved: j.approved,
                       every: j.every, until: j.until, runs: j.runs, remind: j.remind, app: j.app)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in Task { @MainActor in TimerStore.shared.fireDue() } }
    }

    static let maxRuns = 200

    @discardableResult
    func add(_ prompt: String, in seconds: TimeInterval, from: String? = nil, approved: Bool = false, remind: Bool = false,
             every: TimeInterval? = nil, until: Date? = nil, id: UUID? = nil) -> Job {
        var j = Job(id: id ?? UUID(), prompt: prompt, at: Date().addingTimeInterval(seconds), from: from, approved: approved && !remind)
        j.remind = remind
        jobs.removeAll { $0.id == j.id }   // the same id again replaces it
        if let every, let until {   // recurring only with an end
            j.every = max(every, 60)
            j.until = min(until, Date().addingTimeInterval(7 * 86400))
        }
        jobs.append(j)
        jobs.sort { $0.at < $1.at }
        save()
        return j
    }

    /// Cancels the given timers (all of them when `ids` is nil); returns the ones that were cancelled.
    @discardableResult
    func cancel(_ ids: [UUID]? = nil) -> [Job] {
        let gone = jobs.filter { ids == nil || ids!.contains($0.id) }
        jobs.removeAll { j in gone.contains { $0.id == j.id } }
        for j in gone { threads[j.id] = nil }
        save()
        return gone
    }

    /// Edits a timer from the Brain window: text, time, mode, recurrence, app. Keeps its id and run count.
    func update(_ j: Job) {
        guard let i = jobs.firstIndex(where: { $0.id == j.id }) else { return }
        var j = j
        if j.remind == true { j.approved = false }
        if let e = j.every { j.every = max(e, 60); j.until = min(j.until ?? j.at.addingTimeInterval(3600), Date().addingTimeInterval(7 * 86400)) }
        else { j.until = nil }
        jobs[i] = j
        threads[j.id] = nil   // a changed task starts a fresh conversation
        jobs.sort { $0.at < $1.at }
        save()
    }

    /// Timers meant by `what`: numbers from the /timer list ("2", "1 3", "1,3"), an id or its start, or words from the task.
    func find(_ what: String) -> [Job] {
        let w = what.trimmingCharacters(in: .whitespaces).lowercased()
        let nums = w.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Int($0) }
        if !nums.isEmpty, nums.count == w.split(whereSeparator: { $0 == " " || $0 == "," }).count {
            return nums.compactMap { $0 >= 1 && $0 <= jobs.count ? jobs[$0 - 1] : nil }
        }
        if w.count >= 4, case let byId = jobs.filter({ $0.id.uuidString.lowercased().hasPrefix(w) }), !byId.isEmpty { return byId }
        let words = w.split(separator: " ").map(String.init)
        return words.isEmpty ? [] : jobs.filter { j in words.allSatisfy { j.prompt.lowercased().contains($0) } }
    }

    func fireDue() {
        if RenderCheck.stressing { return }   // a test process never runs the user's timers
        let due = jobs.filter { $0.at <= Date() }
        guard !due.isEmpty else { return }
        jobs.removeAll { j in due.contains { $0.id == j.id } }
        for var j in due {
            j.runs = (j.runs ?? 0) + 1
            let last = j.every == nil || (j.runs ?? 0) >= Self.maxRuns || Date().addingTimeInterval(j.every!) > j.until!
            run(j, last: last)
            if !last {   // the next run: from now, so a sleeping Mac doesn't fire a burst of missed ones
                j = Job(id: j.id, prompt: j.prompt, at: Date().addingTimeInterval(j.every!), from: j.from, approved: j.approved,
                        every: j.every, until: j.until, runs: j.runs, remind: j.remind, app: j.app)
                jobs.append(j)
            }
        }
        jobs.sort { $0.at < $1.at }
        save()
    }

    /// Conversation of a recurring job, so its runs follow one another (in memory; after a restart a new one starts).
    private var threads: [UUID: Session] = [:]

    private func run(_ j: Job, last: Bool = true) {
        if j.remind == true { onRemind?(j); return }
        let prompt = j.app.flatMap { BrainApps.find("/" + $0) }.map { "[Použi na to: \($0.name), \($0.hint)] " + j.prompt } ?? j.prompt
        if let s = threads[j.id], !s.running {   // a recurring job's next run continues its conversation
            if last { threads[j.id] = nil }
            running[s.chatId] = s
            s.send(prompt + (last ? " (posledné kolo)" : ""), mark: "⏰ ")
            return
        }
        let s = Session()
        let late = Date().timeIntervalSince(j.at) > 300 ? " (oneskorene, Mac spal alebo Brain nebežal; malo to byť \(j.at.formatted(date: .abbreviated, time: .shortened)))" : ""
        s.runner.extraEnvironment = ["BRAIN_TIMER": "1"]   // Brain refuses to confirm trades from a timer
        s.earlier = "Me: this is a timer I set earlier" + (j.from.map { " in the conversation \"\($0)\"" } ?? "") + late + ". "
            + (j.approved == true
               ? "When I set it I approved doing this without asking again: do it now, and call confirm on its proposal yourself. Trades and orders are the exception: those only get proposed for my yes. Then say briefly what you did."
               : "Do what it asks now and answer briefly. Anything that changes something still needs my yes: end with the proposal.")
        s.chatTitle = (j.every == nil ? "⏰ " : "🔁 ") + HistoryStore.title(from: j.prompt)
        if j.every != nil, !last { threads[j.id] = s }
        running[s.chatId] = s
        s.onFinished = { [weak self, weak s] text, failed in
            guard let self, let s else { return }
            onAnswer?(s.chatId, text, failed)
            running[s.chatId] = nil
        }
        s.send(prompt, mark: "⏰ ")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.iso.encode(jobs).write(to: Self.file, options: .atomic)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e }()
}
