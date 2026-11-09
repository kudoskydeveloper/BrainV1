import Foundation
import SwiftUI

/// What `brain fitness --days N` returns (brain/src/fitness.js). Numbers are Doubles throughout: JSON doesn't say which are whole.
struct Overview: Codable {
    struct Period: Codable { let from: String; let to: String; let days: Double }
    struct Source: Codable { let ok: Bool; let error: String? }
    struct Totals: Codable {
        let sessions: Double
        let strengthSessions: Double
        let hours: Double?
        let km: Double?
        let volumeKg: Double?
        let avgKcal: Double?
        let avgProtein: Double?
        let kcalGoal: Double?
        let loggedDays: Double
        let weightKg: Double?
        let weightDate: String?
        let weightChangeKg: Double?
    }
    struct Week: Codable, Identifiable {
        let week: String
        let sessions: Double, minutes: Double, km: Double, volumeKg: Double
        let bySport: [String: Double]
        var id: String { week }
        var date: Date { Fmt.day(week) }
    }
    struct SportWeek: Codable, Identifiable {
        let week: String
        let sessions: Double, minutes: Double, km: Double, elevationM: Double, volumeKg: Double
        var id: String { week }
        var date: Date { Fmt.day(week) }
    }
    struct Longest: Codable { let id: String; let title: String; let date: String; let km: Double }
    struct SportSummary: Codable, Identifiable {
        let key: String
        let sessions: Double, minutes: Double, km: Double, elevationM: Double
        let avgHr: Double?, avgKm: Double?, avgSpeedKmh: Double?
        let longest: Longest?
        let volumeKg: Double
        let weekly: [SportWeek]
        var id: String { key }
        var sport: Sport { Sport(rawValue: key) ?? .other }
    }
    struct SetValue: Codable { let kg: Double?; let reps: Double?; let seconds: Double? }
    struct ExercisePoint: Codable, Identifiable {
        let date: String
        let workout: String
        let sets: Double, reps: Double
        let topKg: Double?
        let bestSet: SetValue
        let e1rmKg: Double?
        let maxReps: Double?
        let volumeKg: Double
        var id: String { date + workout }
        var day: Date { Fmt.day(date) }
    }
    struct Exercise: Codable, Identifiable, Hashable {
        let name: String
        let muscle: String?
        let equipment: String?
        let kind: String           // weight | reps | duration
        let history: [ExercisePoint]
        let sessions: Double
        let lastDate: String
        let firstDate: String
        let last: SetValue
        let best: SetValue
        let bestDate: String
        let bestE1rmKg: Double?
        let change: Double?
        var id: String { name }
        var weighted: Bool { kind == "weight" }
        /// convertFromSnakeCase makes "best_e1rm_kg" into bestE1RmKg (it capitalizes after the digit), so the keys are spelled out.
        enum CodingKeys: String, CodingKey {
            case name, muscle, equipment, kind, history, sessions, lastDate, firstDate, last, best, bestDate, change
            case bestE1rmKg = "bestE1RmKg"
        }
        static func == (a: Exercise, b: Exercise) -> Bool { a.name == b.name }
        func hash(into h: inout Hasher) { h.combine(name) }
    }
    struct Strength: Codable {
        let historyFrom: String?
        let lastHevyWorkout: String?
        let exercises: [Exercise]
    }
    struct Day: Codable, Identifiable {
        let day: String
        let kcal: Double?, protein: Double?, carbs: Double?, fat: Double?
        var id: String { day }
        var date: Date { Fmt.day(day) }
    }
    struct Today: Codable {
        let day: String?
        let calories: Double?, protein: Double?, carbs: Double?, fat: Double?, waterMl: Double?, goalCalories: Double?
    }
    struct Nutrition: Codable { let goalKcal: Double?; let daily: [Day]; let today: Today? }
    struct WeightPoint: Codable, Identifiable {
        let day: String, kg: Double, source: String
        var id: String { day + source }
        var date: Date { Fmt.day(day) }
    }
    struct LoggedSet: Codable { let type: String?; let kg: Double?; let reps: Double?; let seconds: Double?; let meters: Double? }
    struct LoggedExercise: Codable, Identifiable { let name: String; let sets: [LoggedSet]; var id: String { name } }
    struct Activity: Codable, Identifiable {
        let source: String
        let id: String
        let date: String
        let title: String
        let type: String
        let sport: String
        let minutes: Double?
        let km: Double?
        let volumeKg: Double?
        let sets: Double?
        let exercises: [LoggedExercise]?
        let pace: String?
        let avgHr: Double?
        let maxHr: Double?
        let elevationM: Double?
        let kcal: Double?

        var kind: Sport { Sport(rawValue: sport) ?? .other }
        var symbol: String {
            switch type {
            case let t where t.contains("Hike"): "figure.hiking"
            case let t where t.contains("Virtual"): "figure.indoor.cycle"
            case "InlineSkate": "figure.skating"
            default: kind.symbol
            }
        }
        var url: URL? { source == "strava" ? URL(string: "https://www.strava.com/activities/\(id)") : nil }
        var when: Date { Fmt.dateTime(date) }
    }

    let period: Period
    let generatedAt: String
    let sources: [String: Source]
    let totals: Totals
    let weekly: [Week]
    let sports: [SportSummary]
    let strength: Strength
    let nutrition: Nutrition
    let weight: [WeightPoint]
    let activities: [Activity]

    static func decode(_ data: Data) throws -> Overview {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Overview.self, from: data)
    }

    func sport(_ s: Sport) -> SportSummary? { sports.first { $0.key == s.rawValue } }
    func activities(_ s: Sport) -> [Activity] { activities.filter { $0.sport == s.rawValue } }

    /// Sources that failed, by their display name, with the error.
    var failed: [(name: String, error: String)] {
        let names = ["hevy": "Hevy", "hevy_body": "Hevy (váha)", "strava": "Strava", "strava_stats": "Strava (štatistiky)", "myfitnesspal": "MyFitnessPal"]
        return sources.filter { !$0.value.ok }.map { (names[$0.key] ?? $0.key, $0.value.error ?? "") }.sorted { $0.name < $1.name }
    }
}

/// The sports Brain sorts activities into (brain/src/fitness.js sportOf), with how the app shows them.
enum Sport: String, CaseIterable, Identifiable, Hashable {
    case strength, ride, run, swim, walk, other
    var id: String { rawValue }

    var name: String {
        switch self {
        case .strength: "Silový tréning"
        case .ride: "Bicykel"
        case .run: "Beh"
        case .swim: "Plávanie"
        case .walk: "Chôdza a turistika"
        case .other: "Ostatné"
        }
    }
    var symbol: String {
        switch self {
        case .strength: "figure.strengthtraining.traditional"
        case .ride: "figure.outdoor.cycle"
        case .run: "figure.run"
        case .swim: "figure.pool.swim"
        case .walk: "figure.walk"
        case .other: "figure.mixed.cardio"
        }
    }
    var color: Color {
        switch self {
        case .strength: .orange
        case .ride: .green
        case .run: .pink
        case .swim: .cyan
        case .walk: .yellow
        case .other: .indigo
        }
    }
    /// Distance is what matters for these; for the rest, time.
    var usesDistance: Bool { [.ride, .run, .swim, .walk].contains(self) }
}

enum Muscle {
    static let names: [String: String] = [
        "chest": "Hrudník", "lats": "Široký chrbtový", "upper_back": "Horný chrbát", "lower_back": "Spodný chrbát",
        "biceps": "Biceps", "triceps": "Triceps", "shoulders": "Ramená", "abdominals": "Brucho", "quadriceps": "Stehná – predné",
        "hamstrings": "Stehná – zadné", "glutes": "Sedací sval", "calves": "Lýtka", "forearms": "Predlaktia", "traps": "Trapézy",
        "full_body": "Celé telo", "cardio": "Kardio", "adductors": "Adduktory", "abductors": "Abduktory", "neck": "Krk", "other": "Iné",
    ]
    static func name(_ key: String?) -> String { key.map { names[$0] ?? $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Iné" }
}
