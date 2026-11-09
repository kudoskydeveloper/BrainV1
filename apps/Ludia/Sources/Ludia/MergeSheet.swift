import SwiftUI

/// Zlúčiť s…: pick the record that is the same person as `p` (look-alikes first), choose the name that stays, merge.
struct MergeSheet: View {
    let p: Person
    let people: [Person]
    let onMerge: (Person, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var other: Person?
    @State private var keepName = ""

    var similar: [Person] { people.filter { p.looksLike($0) } }
    var found: [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return people.filter { $0.id != p.id && ($0.name.localizedCaseInsensitiveContains(q) || $0.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
            || $0.emails.contains { $0.localizedCaseInsensitiveContains(q) } || (!q.filter(\.isNumber).isEmpty && $0.phones.contains { $0.contains(q.filter(\.isNumber)) })) }
            .prefix(30).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Zlúčiť „\(p.name)“ s…").font(.title3.weight(.semibold))
                Text("Vyber záznam, ktorý je ten istý človek. Spoja sa kanály, poznámky aj sľuby. Vrátiť to vieš tlačidlom Rozdeliť.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            TextField("Hľadať meno, e-mail alebo číslo", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
            List(selection: Binding(get: { other?.id }, set: { id in
                other = people.first { $0.id == id }
                if let o = other { keepName = bestName(p.name, o.name) }
            })) {
                if !found.isEmpty {
                    Section("Nájdení") { ForEach(found) { MergeRow(x: $0).tag($0.id) } }
                }
                Section(similar.isEmpty ? "Podobní: nikto" : "Podobní") { ForEach(similar) { MergeRow(x: $0).tag($0.id) } }
            }
            .frame(minHeight: 260)
            if let o = other {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Meno", selection: $keepName) {
                        Text(p.name).tag(p.name)
                        if o.name != p.name { Text(o.name).tag(o.name) }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    Text("Spolu: " + Array(Set(p.channels.map(\.channel) + o.channels.map(\.channel))).sorted().joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.top, 12)
            }
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zlúčiť") { if let o = other { onMerge(o, keepName); dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(other == nil)
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
        .onAppear { if similar.count == 1 { other = similar[0]; keepName = bestName(p.name, similar[0].name) } }
    }

    /// The fuller name ("Stanislava Malinová" over "Stanka Malinová" or "Bielikova").
    func bestName(_ a: String, _ b: String) -> String {
        let wa = a.split(separator: " ").count, wb = b.split(separator: " ").count
        return wa != wb ? (wa > wb ? a : b) : (a.count >= b.count ? a : b)
    }
}

struct MergeRow: View {
    let x: Person
    var body: some View {
        HStack(spacing: 10) {
            Avatar(x, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(x.name).font(.body.weight(.medium))
                Text([x.company, x.emails.first, x.phones.first.map(Fmt.phone)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 3) { ForEach(Array(Set(x.channels.map(\.channel))).sorted(), id: \.self) { ChannelIcon(channel: $0) } }.font(.caption2)
        }
        .padding(.vertical, 2)
    }
}
