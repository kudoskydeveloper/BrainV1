import SwiftUI

/// Nastavenia (⌘,): which sources Ľudia read and whether each can add new people, plus the default intervals.
/// Saved in Brain (`brain ludia-sources`), so Claude sees the same list.
struct SettingsView: View {
    @ObservedObject var store: Store

    var sources: [String: String] { store.data?.settings.sources ?? [:] }

    var body: some View {
        Form {
            Section {
                ForEach(Source.allCases) { s in SourceRow(s: s, mode: sources[s.rawValue] ?? "off") { store.setSettings(sources: [s.rawValue: $0]) } }
            } header: {
                Text("Zdroje")
            } footer: {
                Text("„Pridáva ľudí“ vypnuté = zdroj len doplní posledný kontakt ľuďom, ktorí už v zozname sú (napr. LinkedIn, kde je veľa studených chatov). Beeper chaty sú vždy len 1:1, nikdy skupiny.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CrmSection(store: store)
            Section("Ozvi sa") {
                Picker("Nový sledovaný: ozvať sa", selection: Binding(get: { store.data?.settings.everyDays ?? 60 }, set: { store.setSettings(everyDays: $0) })) {
                    ForEach(Fmt.intervals, id: \.self) { Text(Fmt.every($0)).tag($0) }
                }
                Picker("Zabúdaš: ticho dlhšie ako", selection: Binding(get: { store.data?.settings.fadingDays ?? 60 }, set: { store.setSettings(fadingDays: $0) })) {
                    ForEach([30, 60, 90, 180], id: \.self) { Text("\($0) dní").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 760)
        .overlay(alignment: .bottomTrailing) {
            if store.loading { ProgressView().controlSize(.small).padding(12) }
        }
    }
}

struct SourceRow: View {
    let s: Source
    let mode: String
    let change: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.symbol).foregroundStyle(s.color).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { mode != "off" }, set: { change($0 ? (s == .contacts || s == .LinkedIn || s == .Instagram ? "enrich" : "add") : "off") })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text(s.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Pridáva ľudí", isOn: Binding(get: { mode == "add" }, set: { change($0 ? "add" : "enrich") }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(mode == "off")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Pracovné CRM: which MCP server and read tool to ask about a person (with their e-mail), for which groups.
/// Saved in Brain; the code knows no company, so a new job only means changing this.
struct CrmSection: View {
    @ObservedObject var store: Store
    @State private var servers: [CrmServer] = []
    @State private var on = false
    @State private var label = "Pracovné CRM"
    @State private var server = ""
    @State private var tool = ""
    @State private var args = #"{"q": "{email}"}"#
    @State private var groups: Set<String> = ["work"]
    @State private var loaded = false

    var saved: Overview.Crm? { store.data?.settings.crm }
    var current: Overview.Crm { .init(label: label, server: server, tool: tool, args: args, groups: Array(groups).sorted()) }
    var validJSON: Bool {
        let t = args.replacingOccurrences(of: "{email}", with: "a@b.c").replacingOccurrences(of: "{name}", with: "A B")
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil
    }
    var tools: [CrmServer.Tool] { servers.first { $0.server == server }?.tools ?? [] }

    var body: some View {
        Section {
            Toggle("Hľadať ľudí v pracovnom CRM", isOn: $on)
                .onChange(of: on) { _, v in if !v, saved != nil { store.setSettings(crm: .some(nil)) } }
            if on {
                TextField("Názov karty", text: $label)
                Picker("MCP server", selection: $server) {
                    Text("Vyber…").tag("")
                    ForEach(servers) { Text($0.server).tag($0.server) }
                }
                .onChange(of: server) { _, _ in if !tools.contains(where: { $0.name == tool }) { tool = tools.first?.name ?? "" } }
                Picker("Nástroj", selection: $tool) {
                    if tools.isEmpty { Text("—").tag("") }
                    ForEach(tools, id: \.name) { Text($0.name).tag($0.name) }
                }
                .help(tools.first { $0.name == tool }?.description ?? "")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Argumenty (JSON)")
                    TextField("", text: $args, axis: .vertical).font(.system(.callout, design: .monospaced)).lineLimit(1...4)
                    Text(validJSON ? "{email} a {name} sa nahradia mailom a menom človeka." : "Toto nie je platný JSON.")
                        .font(.caption).foregroundStyle(validJSON ? Color.secondary : Color.red)
                }
                HStack {
                    Text("Pre skupiny")
                    Spacer()
                    ForEach(Business.allCases) { b in
                        Toggle(b.name, isOn: Binding(get: { groups.contains(b.rawValue) }, set: { if $0 { groups.insert(b.rawValue) } else { groups.remove(b.rawValue) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Spacer()
                    Button("Uložiť") { store.setSettings(crm: .some(current)) }
                        .disabled(server.isEmpty || tool.isEmpty || !validJSON || groups.isEmpty || current == saved)
                }
            }
        } header: {
            Text("Pracovné CRM")
        } footer: {
            Text("Voliteľné. V detaile človeka sa ukáže, čo o ňom vráti zvolený nástroj (len čítanie). Pri zmene práce stačí zmeniť server.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let c = saved { on = true; label = c.label; server = c.server; tool = c.tool; args = c.args; groups = Set(c.groups) }
            servers = await store.crmServers()
        }
    }
}
