#if os(iOS)
import EventKit
import HomeCore
import SwiftUI

@main
struct HomeMobileApp: App {
    @State private var store = Store()
    @State private var devices = Devices()
    @State private var calendar = MobileCalendar()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(devices)
                .environment(calendar)
                .tint(.leaf)
                // home://auth#… from the "forgot password" e-mail.
                .onOpenURL { url in
                    guard url.scheme == "home", url.host == "auth" else { return }
                    Task { try? await store.finishSignIn(url) }
                }
                // Other members' changes every 30 s while the app is open.
                .task {
                    while !Task.isCancelled {
                        await store.sync()
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
                .onChange(of: phase) { _, p in if p == .active { Task { await store.sync(); calendar.reload() } } }
        }
    }
}

extension Color {
    /// The icon's leaf green.
    static let leaf = Color(red: 0.24, green: 0.62, blue: 0.27)
}

/// Plans from the iPhone's calendars, the next 14 days.
@MainActor @Observable
final class MobileCalendar {
    struct Event: Identifiable, Hashable {
        let id: String, title: String, start: Date, end: Date, allDay: Bool, calendar: String, color: Color
    }
    private(set) var events: [Event] = []
    private(set) var denied = false
    @ObservationIgnored private let store = EKEventStore()

    func load() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined: denied = !(((try? await store.requestFullAccessToEvents()) ?? false))
        default: denied = true
        }
        reload()
    }

    func reload() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { events = []; return }
        let pred = store.predicateForEvents(withStart: Day.today.startOfDay, end: Day.today.adding(days: 14).startOfDay, calendars: nil)
        events = store.events(matching: pred)
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { Event(id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Bez názvu",
                         start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay, calendar: $0.calendar.title,
                         color: Color(cgColor: $0.calendar.cgColor)) }
    }

    func on(_ d: Day) -> [Event] {
        events.filter { e in e.allDay ? (Day(e.start)...max(Day(e.start), Day(e.end.addingTimeInterval(-1)))).contains(d) : Day(e.start) == d }
    }
}
#else
@main
enum HomeMobileStub {
    static func main() { print("HomeMobile runs on iOS; build it with ./build-ios.sh") }
}
#endif
