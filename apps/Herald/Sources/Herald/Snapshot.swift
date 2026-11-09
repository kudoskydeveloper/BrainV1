import AppKit
import SwiftUI

/// `Herald --snapshot <dir> [state.json]`: renders rows and details to PNG (light and dark) and quits, for checking the
/// design without clicking through the app. Without a file it reads the running server.
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        var data = Data()
        if i + 2 < args.count { data = (try? Data(contentsOf: URL(fileURLWithPath: args[i + 2]))) ?? Data() }
        else {
            let sem = DispatchSemaphore(value: 0)
            Task.detached { if case .success(let d) = await Store.get("state") { data = d }; sem.signal() }
            sem.wait()
        }
        let s: AppState; do { s = try AppState.decode(data) } catch { print("decode failed", error); exit(1) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let inProject = s.connections.filter { !$0.projects.isEmpty }
        let person = inProject.max { ($0.note.count, $0.tags.count) < ($1.note.count, $1.tags.count) } ?? s.connections[0]
        var pages: [(String, AnyView, CGFloat)] = [
            ("people", AnyView(Rows(inProject.prefix(12).map { AnyView(PersonRow(c: $0, state: s)) })), 380),
            ("inbox", AnyView(Rows(s.conversations.filter(s.needsReply).prefix(10).map { AnyView(ConversationRow(c: $0, state: s)) })), 380),
            ("person", AnyView(PersonDetail(c: person, state: s, store: .shared)), 760),
        ]
        if let p = s.projects.first { pages.append(("project", AnyView(ProjectOverview(project: p, state: s, onEdit: {})), 760)) }
        if let p = s.prospects.first {
            pages.append(("prospects", AnyView(Rows(s.prospects.prefix(8).map { AnyView(ProspectRow(p: $0, state: s)) })), 380))
            pages.append(("prospect", AnyView(ProspectDetail(p: p, state: s, store: .shared)), 760))
        }
        for (name, view, width) in pages {
            for dark in [false, true] {
                let v = view.environment(\.snapshot, true).frame(width: width).frame(minHeight: 200).background(dark ? Color(white: 0.12) : .white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let r = ImageRenderer(content: v)
                r.scale = 1
                guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("render failed \(name)"); continue }
                try? png.write(to: dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
            }
            print("ok \(name)")
        }
        exit(0)
    }
}

/// Lists render empty in ImageRenderer, so rows go in a plain stack.
private struct Rows: View {
    let rows: [AnyView]
    init(_ r: [AnyView]) { rows = r }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0]; Divider() } }.padding(16)
    }
}
