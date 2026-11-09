import CourierCore
import SwiftUI

/// The projects board: one glass card per project with its unread count and newest messages.
struct BoardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.projects.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Nástenka projektov").font(.title2.weight(.semibold))
                        Text("Zoskup schránky, priečinky a odosielateľov podľa projektov. Každý projekt má svoju doručenú poštu.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 320)
                        Button { model.editingProject = Project(name: "") } label: { Label("Nový projekt", systemImage: "plus") }
                            .buttonStyle(.glassProminent).controlSize(.large)
                    }
                    .padding(.vertical, 60).frame(maxWidth: .infinity)
                } else {
                    BoardHeader(title: "Projekty", symbol: "square.grid.2x2")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        ForEach(model.projects) { p in ProjectCard(project: p) }
                        Button { model.editingProject = Project(name: "") } label: {
                            Label("Nový projekt", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 120)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    }
                    .padding(.horizontal, 16)
                }
                BoardHeader(title: "Tikety", symbol: "checklist").padding(.top, 14)
                TicketBoard().padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .navigationTitle("Nástenka")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshAll() } } label: { Label("Obnoviť", systemImage: "arrow.clockwise") }
                    .disabled(model.syncing)
            }
        }
    }
}

struct BoardHeader: View {
    let title: String, symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
    }
}

/// Ticket board under the projects: one column per status, conversations dragged between columns change their status.
struct TicketBoard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let _ = model.tickets   // redraw when a status changes
        HStack(alignment: .top, spacing: 14) {
            ForEach(TicketStatus.allCases, id: \.self) { s in TicketColumn(status: s) }
        }
    }
}

struct TicketColumn: View {
    @EnvironmentObject var model: AppModel
    let status: TicketStatus
    @State private var targeted = false

    var tint: Color { status == .done ? .green : (status == .waiting ? .orange : .blue) }

    var body: some View {
        var seen = Set<String>()
        let all = model.store.messages(status: status, limit: 200).filter { seen.insert($0.threadKey).inserted }
        let shown = status == .done ? Array(all.prefix(8)) : all
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.symbol).foregroundStyle(tint)
                Text(status.title).font(.headline)
                Spacer()
                Text("\(all.count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = .status(status) }
            if shown.isEmpty {
                Text(status == .open ? "Žiadne otvorené tikety" : "Prázdne").font(.subheadline).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            ForEach(shown) { m in TicketRow(m: m, tint: tint) }
            if shown.count < all.count {
                Button("Všetky (\(all.count))") { model.selection = .status(status) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(tint.opacity(targeted ? 0.25 : 0.06)), in: .rect(cornerRadius: 18))
        .dropDestination(for: String.self) { items, _ in
            let ms = items.compactMap { model.droppedMessage($0) }
            for m in ms { model.setStatus(status, for: m) }
            return !ms.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

struct TicketRow: View {
    @EnvironmentObject var model: AppModel
    let m: MessageSummary
    let tint: Color

    var body: some View {
        let tags = model.ticket(m)?.tags ?? []
        Button {
            model.selection = .status(model.ticket(m)?.status ?? .open)
            model.selectedMessageID = m.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.fromDisplay).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(m.date.listLabel).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(m.subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { t in
                            Text(t).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(ProjectColor.of(model.tag(t)?.color ?? "").opacity(0.18), in: .capsule)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.5), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .draggable("message:\(m.id)")
        .contextMenu { TicketMenu(m: m) }
    }
}

struct ProjectCard: View {
    @EnvironmentObject var model: AppModel
    let project: Project

    var body: some View {
        let msgs = model.store.messages(project: project, limit: 4)
        let unread = model.unread(project: project)
        let tint = ProjectColor.of(project.color)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: project.symbol).font(.title3).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.headline)
                    Text(sourcesLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if unread > 0 {
                    Text("\(unread)").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(tint, in: .capsule)
                }
            }
            if msgs.isEmpty {
                Text("Zatiaľ žiadne správy").font(.subheadline).foregroundStyle(.tertiary).padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(msgs) { m in
                        Button {
                            model.selection = .project(project.id)
                            model.selectedMessageID = m.id
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(m.seen ? Color.clear : tint).frame(width: 6, height: 6)
                                Text(m.fromDisplay).font(.subheadline.weight(m.seen ? .regular : .semibold)).lineLimit(1).frame(width: 90, alignment: .leading)
                                Text(m.subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(m.date.listLabel).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
        .onTapGesture { model.selection = .project(project.id) }
        .contextMenu {
            Button("Upraviť projekt…") { model.editingProject = project }
            Button("Odstrániť projekt", role: .destructive) { model.delete(project) }
        }
    }

    var sourcesLabel: String {
        let parts = project.sources.map { s -> String in
            switch s.kind {
            case .account: return model.account(s.accountID ?? "")?.email ?? "schránka"
            case .folder: return model.folder(s.accountID ?? "", s.folder ?? "")?.displayName ?? (s.folder ?? "")
            case .sender: return s.pattern ?? ""
            }
        }
        return parts.isEmpty ? "Bez zdrojov – uprav projekt" : parts.joined(separator: ", ")
    }
}
