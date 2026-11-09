import SwiftUI

/// Long lists (2,800 contacts) stay quick: plain rows, no per-row state.
struct PeopleList: View {
    let state: AppState
    let people: [Connection]
    @Binding var selection: Set<String>
    let title: String
    let empty: (String, String, String)

    var body: some View {
        Group {
            if people.isEmpty {
                ContentUnavailableView(empty.0, systemImage: empty.1, description: Text(empty.2))
            } else {
                List(people, selection: $selection) { c in PersonRow(c: c, state: state).tag(c.id) }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(Fmt.people(people.count))
    }
}

/// A project's people grouped by stage, in pipeline order (meeting first: that's what matters).
struct ProjectList: View {
    let state: AppState
    let project: Project?
    let people: [Connection]
    @Binding var selection: Set<String>

    var body: some View {
        Group {
            if let project, people.isEmpty {
                ContentUnavailableView("V projekte nikto nie je", systemImage: "flag",
                                       description: Text("Pridaj ľudí do projektu \(project.name) v ich detaile alebo cez Claude („pridaj ich do \(project.name)“)."))
            } else if let project {
                List(selection: $selection) {
                    ForEach(state.stages.sorted { $0.rank > $1.rank }) { st in
                        let group = people.filter { $0.projects[project.id]?.stage == st.key }
                        if !group.isEmpty {
                            Section {
                                ForEach(group) { c in PersonRow(c: c, state: state, inProject: project.id).tag(c.id) }
                            } header: {
                                Label("\(st.label) · \(group.count)", systemImage: st.symbol).foregroundStyle(st.tint)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(project?.name ?? "Projekt")
        .navigationSubtitle(Fmt.people(people.count))
    }
}

struct PersonRow: View {
    let c: Connection
    let state: AppState
    /// Inside a project's list the stage is the section, so the row shows when they got there instead.
    var inProject: String?

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: c.name, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(c.name).font(.body.weight(.medium)).lineLimit(1)
                    if c.doNotContact { Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(.red).help("Nekontaktovať") }
                }
                Text(c.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    if inProject == nil {
                        ForEach(c.projects.sorted { $0.key < $1.key }, id: \.key) { k, m in
                            StageBadge(project: state.project(k), stage: state.stage(m.stage))
                        }
                    }
                    Text(lastLine).font(.caption).foregroundStyle(lastTint).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    var lastLine: String {
        guard let d = c.daysSinceTalk else { return "nikdy ste si nepísali" }
        return (c.lastFrom == "them" ? "napísal(a) " : "písal si ") + Fmt.ago(d)
    }
    var lastTint: Color { c.lastFrom == "them" && (c.daysSinceTalk ?? 99) <= 30 ? .orange : .secondary }
}

struct ConversationList: View {
    let state: AppState
    let conversations: [Conversation]
    @Binding var selection: Set<String>
    let title: String
    let empty: (String, String, String)

    var body: some View {
        Group {
            if conversations.isEmpty {
                ContentUnavailableView(empty.0, systemImage: empty.1, description: Text(empty.2))
            } else {
                List(conversations, selection: $selection) { c in
                    ConversationRow(c: c, state: state).tag(c.id).contextMenu {
                        if state.isDone(c) {
                            Button { Store.shared.markDone([c], undo: true) } label: { Label("Vrátiť do Čaká na teba", systemImage: "arrow.uturn.backward") }
                        } else if c.theyWroteLast {
                            Button { Store.shared.markDone([c]) } label: { Label("Vybavené", systemImage: "checkmark.circle") }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(conversations.count == 1 ? "1 konverzácia" : "\(conversations.count) konverzácií")
    }
}

struct ConversationRow: View {
    let c: Conversation
    let state: AppState
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: c.with, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(c.with).font(.body.weight((c.unread ?? 0) > 0 ? .bold : .medium)).lineLimit(1)
                    Spacer()
                    Text(Fmt.ago(c.daysSinceLast)).font(.caption).foregroundStyle(.secondary)
                }
                Text((c.lastFrom == "me" ? "Ty: " : "") + (c.lastText ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let id = c.connectionId, let p = state.byId[id], !p.projects.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(p.projects.sorted { $0.key < $1.key }, id: \.key) { k, m in StageBadge(project: state.project(k), stage: state.stage(m.stage)) }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProspectList: View {
    let state: AppState
    let prospects: [Prospect]
    @Binding var selection: Set<String>
    let title: String
    let empty: (String, String, String)
    let onFind: () -> Void

    var body: some View {
        Group {
            if prospects.isEmpty {
                ContentUnavailableView {
                    Label(empty.0, systemImage: empty.1)
                } description: { Text(empty.2) } actions: { Button("Hľadať ľudí…", action: onFind) }
            } else {
                List(prospects, selection: $selection) { p in ProspectRow(p: p, state: state).tag(p.slug) }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(Fmt.people(prospects.count)) · pozvánky \(state.inviteBudget.today)/\(state.inviteBudget.dailyCap) dnes, \(state.inviteBudget.week)/\(state.inviteBudget.weeklyCap) týždeň")
    }
}

struct ProspectRow: View {
    let p: Prospect
    let state: AppState
    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: p.name, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(p.name).font(.body.weight(.medium)).lineLimit(1)
                    if let d = p.degree { Text(d).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Text(p.headline ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    ForEach((p.projects ?? [:]).sorted { $0.key < $1.key }, id: \.key) { k, m in StageBadge(project: state.project(k), stage: state.stage(m.stage)) }
                    if let at = Fmt.iso(p.invitedAt) {
                        Label("pozvaný \(Fmt.ago(Fmt.daysAgo(at)))", systemImage: "paperplane").font(.caption).foregroundStyle(.indigo)
                    } else if p.pending == true {
                        Text("pozvánka čaká").font(.caption).foregroundStyle(.purple)
                    } else if let l = p.location {
                        Text(l).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct InviteList: View {
    let invites: [SentInvite]
    @Binding var selection: Set<String>
    let title: String
    let syncedAt: String?

    var body: some View {
        Group {
            if invites.isEmpty {
                ContentUnavailableView("Žiadne čakajúce pozvánky", systemImage: "hourglass", description: Text("Stiahni ich z LinkedInu (Stiahnuť › Čakajúce pozvánky)."))
            } else {
                List(invites, selection: $selection) { i in
                    HStack(spacing: 10) {
                        Avatar(name: i.name, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.name).font(.body.weight(.medium)).lineLimit(1)
                            Text(i.headline ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(Fmt.ago(i.daysAgo)).font(.caption).foregroundStyle(i.daysAgo > 30 ? .orange : .secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(i.id)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(invites.count) · najstaršie navrchu" + (Fmt.iso(syncedAt).map { " · stiahnuté \(Fmt.ago(Fmt.daysAgo($0)))" } ?? ""))
    }
}
