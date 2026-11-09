import SwiftUI

/// LinkedIn people search (2nd / 3rd degree). Each page is one LinkedIn search, and free accounts have a monthly limit.
struct FindSheet: View {
    @ObservedObject var store: Store
    @Binding var folder: Folder?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("findKeywords") private var keywords = ""
    @AppStorage("findCountry") private var country = ""
    @AppStorage("findDegree") private var degree = "2nd"
    @AppStorage("findProject") private var project = ""

    var body: some View {
        Form {
            Section {
                TextField("Kľúčové slová", text: $keywords, prompt: Text("napr. head of customer service"))
                Picker("Krajina", selection: $country) {
                    Text("Akákoľvek").tag("")
                    ForEach(store.state?.countries ?? [], id: \.self) { Text($0).tag($0) }
                }
                Picker("Stupeň", selection: $degree) {
                    Text("2. stupeň").tag("2nd"); Text("3. stupeň").tag("3rd"); Text("2. aj 3.").tag("2nd+3rd")
                }
                .pickerStyle(.segmented)
                Picker("Do projektu", selection: $project) {
                    Text("Žiadny").tag("")
                    ForEach(store.state?.projects.filter { $0.archived != true } ?? []) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("Jedna strana výsledkov je jedno hľadanie na LinkedIne (bezplatný účet má mesačný limit). Profily sa neotvárajú, nikto nedostane upozornenie. Nájdení ľudia pribudnú medzi Prospektov\(project.isEmpty ? "" : " a do projektu ako Lead").")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle("Hľadať ľudí")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Zrušiť") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Hľadať") {
                    store.findPeople(keywords: keywords, country: country.isEmpty ? nil : country, degree: degree, project: project.isEmpty ? nil : project, page: 1)
                    folder = .prospects
                    dismiss()
                }
                .disabled(keywords.trimmingCharacters(in: .whitespaces).isEmpty || store.busy != nil)
            }
            if !store.found.isEmpty {
                ToolbarItem {
                    Button("Ďalšia strana") {
                        let next = store.found.count / 10 + 1
                        store.findPeople(keywords: keywords, country: country.isEmpty ? nil : country, degree: degree, project: project.isEmpty ? nil : project, page: next)
                        folder = .prospects
                        dismiss()
                    }
                    .disabled(store.busy != nil)
                }
            }
        }
    }
}

/// The user's own click on a person they picked, with the exact note shown before anything is sent.
struct InviteSheet: View {
    let p: Prospect
    let state: AppState
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var project = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Komu") { VStack(alignment: .trailing) { Text(p.name); Text(p.headline ?? "").font(.caption).foregroundStyle(.secondary) } }
                Picker("Projekt", selection: $project) {
                    Text("Žiadny").tag("")
                    ForEach(state.projects.filter { $0.archived != true }) { Text($0.name).tag($0.id) }
                }
            }
            Section {
                TextField("Bez správy", text: $note, axis: .vertical).lineLimit(3...6)
            } header: { Text("Správa k pozvánke (voliteľná)") } footer: {
                Text("\(note.count)/200. Bezplatný účet má len pár pozvánok so správou za mesiac, bez správy je to bezpečnejšie.")
                    .foregroundStyle(note.count > 200 ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { project = p.projects?.keys.sorted().first ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Zrušiť") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Poslať pozvánku") {
                    store.invite(p, note: note.trimmingCharacters(in: .whitespacesAndNewlines), project: project.isEmpty ? nil : project)
                    dismiss()
                }
                .disabled(note.count > 200)
            }
        }
    }
}

struct ProjectSheet: View {
    @ObservedObject var store: Store
    let project: Project?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var playbook = ""

    var body: some View {
        Form {
            Section {
                TextField("Názov", text: $name, prompt: Text("napr. 10T"))
                TextField("Playbook", text: $playbook, prompt: Text(project?.id ?? "rovnaký ako názov"))
            } footer: {
                Text("Playbook je súbor ~/.linkedin-mcp/playbooks/<názov>.md: komu písať, komu nikdy, tón a ponuka. Claude ho číta pred každým oslovením. Nový napíše Claude, keď mu povieš „sprav LinkedIn playbook pre \(name.isEmpty ? "projekt" : name)“.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { name = project?.name ?? ""; playbook = project?.playbook ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Zrušiť") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(project == nil ? "Vytvoriť" : "Uložiť") {
                    store.saveProject(name: name.trimmingCharacters(in: .whitespaces), id: project?.id, playbook: playbook.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
