import HomeCore
import SwiftUI

/// The next 14 days: calendar plans and the day's chores, day by day.
struct PlanView: View {
    @Environment(Store.self) private var store
    @Environment(Events.self) private var events
    var today = Day.today

    var body: some View {
        Page {
            HStack(alignment: .firstTextBaseline) {
                Text("Plán").font(.largeTitle.weight(.semibold))
                Spacer()
                Text("Najbližších 14 dní").foregroundStyle(.secondary)
            }
            if events.access == .denied {
                Notice(symbol: "calendar.badge.exclamationmark", text: "Home nevidí kalendáre. Povoľ mu ich v Nastaveniach › Súkromie › Kalendáre.")
                    .onTapGesture { Events.openPrivacySettings() }
            }
            ForEach(0..<14, id: \.self) { i in
                let d = today.adding(days: i)
                let plans = events.on(d)
                let chores = store.dayTasks(on: d)
                Card(Fmt.relative(d, today: today), subtitle: i < 2 ? Fmt.weekday(d) : nil) {
                    if plans.isEmpty && chores.isEmpty {
                        Text("Nič naplánované.").font(.callout).foregroundStyle(.secondary).padding(.leading, 6)
                    }
                    if !plans.isEmpty { Rows(items: plans, inset: 18) { EventRow(event: $0) } }
                    if !plans.isEmpty && !chores.isEmpty { Divider() }
                    if !chores.isEmpty { Rows(items: chores) { ChoreRow(due: $0) } }
                }
            }
        }
    }
}
