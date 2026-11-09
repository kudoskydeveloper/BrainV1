import AppKit
import EventKit
import HomeCore
import SwiftUI

/// Plans from the Mac's calendars (iCloud, Google, whatever Calendar has), the next 14 days.
@MainActor @Observable
final class Events {
    static let shared = Events()

    struct Event: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let calendar: String
        let color: Color
        var day: Day { Day(start) }
    }

    enum Access { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    private(set) var events: [Event] = []
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in Events.shared.reload() }
        }
    }

    /// Asks for calendar access once (the system dialog), then loads.
    func load() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined:
            access = ((try? await store.requestFullAccessToEvents()) ?? false) ? .granted : .denied
        default: access = .denied
        }
        reload()
    }

    func reload() {
        guard access == .granted else { events = []; return }
        let start = Day.today.startOfDay
        let end = Day.today.adding(days: 14).startOfDay
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: pred)
            .filter { !$0.calendar.title.localizedCaseInsensitiveContains("narodenin") || $0.isAllDay }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { e in
                Event(id: e.calendarItemIdentifier + "\(e.startDate.timeIntervalSince1970)", title: e.title ?? "Bez názvu",
                      start: e.startDate, end: e.endDate, allDay: e.isAllDay, calendar: e.calendar.title,
                      color: Color(nsColor: e.calendar.color ?? .systemBlue))
            }
    }

    func on(_ d: Day) -> [Event] {
        events.filter { e in e.allDay ? (Day(e.start)...max(Day(e.start), Day(e.end.addingTimeInterval(-1)))).contains(d) : e.day == d }
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }
}

/// What the window shows and messages for the sign-in screen; links (home://shopping, Hangar) switch the section.
@MainActor @Observable
final class AppState {
    static let shared = AppState()
    var section: Section = .today
    var linkError: String?
}

enum Section: String, Hashable, CaseIterable {
    case today, tasks, shopping, plan, devices, household

    var title: String {
        switch self {
        case .today: "Dnes"
        case .tasks: "Úlohy"
        case .shopping: "Nákup"
        case .plan: "Plán"
        case .devices: "Zariadenia"
        case .household: "Domácnosť"
        }
    }
    var symbol: String {
        switch self {
        case .today: "sun.max.fill"
        case .tasks: "checklist"
        case .shopping: "cart.fill"
        case .plan: "calendar"
        case .devices: "lightbulb.2.fill"
        case .household: "house.fill"
        }
    }
    var color: Color {
        switch self {
        case .today: .orange
        case .tasks: .blue
        case .shopping: .green
        case .plan: .red
        case .devices: .yellow
        case .household: .indigo
        }
    }
    init?(host: String) {
        self.init(rawValue: host)
    }
}
