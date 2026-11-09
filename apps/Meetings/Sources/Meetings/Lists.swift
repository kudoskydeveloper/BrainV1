import SwiftUI

/// Upcoming meetings grouped by day, as in Calendar's list view.
struct UpcomingList: View {
    let items: [Upcoming]
    @Binding var selection: Pick?

    var days: [(Date, [Upcoming])] {
        let groups = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.startDate) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.start < $1.start }) }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Žiadne meetingy", systemImage: "calendar", description: Text("V najbližších dvoch týždňoch nemáš meeting s inými ľuďmi."))
            } else {
                List(selection: $selection) {
                    ForEach(days, id: \.0) { day, list in
                        Section(Fmt.relativeDay(day)) {
                            ForEach(list) { u in UpcomingRow(u: u).tag(Pick.upcoming(u.id)) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Najbližšie")
        .navigationSubtitle("\(items.count) meetingov · 14 dní")
    }
}

struct UpcomingRow: View {
    let u: Upcoming
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.time(u.startDate)).font(.callout.weight(.semibold)).monospacedDigit()
                Text(Fmt.time(u.endDate)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 44, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(u.isNow ? Color.red : .accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(u.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    AvatarStack(people: u.people, max: 3, size: 18)
                    Text(u.people.prefix(2).map(\.display).joined(separator: ", ") + (u.people.count > 2 ? " a ďalší" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if u.join != nil { Image(systemName: "video.fill").font(.caption).foregroundStyle(.green).help("Online meeting") }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Recordings grouped by month, newest first, like Mail.
struct RecordingList: View {
    let items: [Recording]
    @Binding var selection: Pick?
    let title: String
    var onMove: (Recording, Business) -> Void = { _, _ in }
    var onDelete: (Recording) -> Void = { _ in }

    var months: [(String, [Recording])] {
        let f = { (r: Recording) in r.day.formatted(.dateTime.month(.wide).year().locale(Fmt.sk)) }
        var order: [String] = [], groups: [String: [Recording]] = [:]
        for r in items.sorted(by: { $0.day > $1.day }) {
            let k = f(r)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(r)
        }
        return order.map { ($0.prefix(1).capitalized + $0.dropFirst(), groups[$0]!) }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Žiadne nahrávky", systemImage: "waveform", description: Text("Brain sem dáva nahrávky z Fathomu (každých 30 minút)."))
            } else {
                List(selection: $selection) {
                    ForEach(months, id: \.0) { month, list in
                        Section(month) {
                            ForEach(list) { r in
                                RecordingRow(r: r).tag(Pick.recording(r.path))
                                    .contextMenu { RecordingActions(r: r, onMove: onMove, onDelete: onDelete) }
                            }
                        }
                    }
                }
                .onDeleteCommand {
                    if case .recording(let p) = selection, let r = items.first(where: { $0.path == p }) { onDelete(r) }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(items.count) nahrávok")
    }
}

struct RecordingRow: View {
    let r: Recording
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(r.kind.color).frame(width: 7, height: 7)
                Text(r.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 6)
                Text(Fmt.dateYear(r.day)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let g = r.gist {
                Text(g).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                if let m = r.minutes { Label(Fmt.duration(m), systemImage: "clock").labelStyle(.titleAndIcon) }
                if !r.people.isEmpty { Label(r.people.prefix(2).map(\.display).joined(separator: ", "), systemImage: "person.2") }
                if !r.actionItems.isEmpty { Label("\(r.actionItems.count)", systemImage: "checklist") }
            }
            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Move to another business's folder and delete: in the row's context menu and the detail's toolbar.
struct RecordingActions: View {
    let r: Recording
    let onMove: (Recording, Business) -> Void
    let onDelete: (Recording) -> Void

    var body: some View {
        Menu {
            ForEach(Business.allCases.filter { $0 != r.kind }) { b in
                Button { onMove(r, b) } label: { Label(b.name, systemImage: b.symbol) }
            }
        } label: { Label("Presunúť do", systemImage: "tray.and.arrow.down") }
        Divider()
        Button(role: .destructive) { onDelete(r) } label: { Label("Vymazať…", systemImage: "trash") }
    }
}
