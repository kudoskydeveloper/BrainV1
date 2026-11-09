#if os(iOS)
import SwiftUI
import CourierCore

@main
struct CourierMobileApp: App {
    @State private var model = MobileModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.refresh() }
        }
    }
}

struct RootView: View {
    @Environment(MobileModel.self) private var model
    @State private var query = ""

    var body: some View {
        @Bindable var model = model
        TabView {
            Tab("Doručené", systemImage: "tray") { InboxView() }
            Tab("Projekty", systemImage: "square.grid.2x2") { ProjectsView() }
            Tab("Nastavenia", systemImage: "gearshape") { SettingsView() }
            Tab("Hľadať", systemImage: "magnifyingglass", role: .search) { SearchView(query: query) }
        }
        // On the TabView (not inside the search tab), so iOS 26 morphs the tab bar into the field and keeps the
        // close button that hides the keyboard and goes back to the other tabs.
        .searchable(text: $query, prompt: "Hľadať v pošte")
        .alert("Chyba", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.lastError ?? "") }
    }
}

// MARK: Shared bits

enum ProjectColor {
    static func of(_ name: String) -> Color {
        switch name {
        case "indigo": .indigo; case "purple": .purple; case "pink": .pink; case "red": .red; case "orange": .orange
        case "yellow": .yellow; case "green": .green; case "mint": .mint; case "teal": .teal; case "gray": .gray
        default: .blue
        }
    }
}

/// Round avatar with initials; the color follows the address so a sender always looks the same.
struct Avatar: View {
    let name: String
    let address: String
    var size: CGFloat = 40

    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .green, .mint, .teal, .cyan, .brown]

    var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter }).prefix(2)
        let s = words.compactMap(\.first).map(String.init).joined()
        return (s.isEmpty ? String(address.prefix(1)) : s).uppercased()
    }

    var color: Color {
        var h: UInt32 = 5381
        for b in address.lowercased().utf8 { h = (h &* 33) &+ UInt32(b) }
        return Self.palette[Int(h % UInt32(Self.palette.count))]
    }

    var body: some View {
        Circle().fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white))
    }
}

enum MailDate {
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "včera" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return d.formatted(.dateTime.day().month(.abbreviated)) }
        return d.formatted(date: .numeric, time: .omitted)
    }
}
#else
@main
enum CourierMobileStub {
    static func main() { print("CourierMobile je iPhone appka, zostav ju cez ./build-ios.sh") }
}
#endif
