import AppKit
import SwiftUI

/// `Ludia --snapshot <dir> [ludia.json]`: renders the lists, a person's detail and the settings to PNG (light and dark) and
/// quits, for checking the design without clicking through the app. Loads one detail from Brain.
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let data: Data
        if i + 2 < args.count { data = (try? Data(contentsOf: URL(fileURLWithPath: args[i + 2]))) ?? Data() }
        else if case .success(let d) = Store.run(["ludia"]) { data = d } else { data = Data() }
        let o: Overview; do { o = try Overview.decode(data) } catch { print("decode failed", error); exit(1) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // the person with the most channels, so every card shows
        let p = o.people.max { a, b in (Set(a.channels.map(\.channel)).count, a.score) < (Set(b.channels.map(\.channel)).count, b.score) }
        var pages: [(String, AnyView, CGFloat)] = [
            ("all-list", AnyView(SnapRows(Array(o.people.prefix(14)))), 360),
            ("fading-list", AnyView(SnapRows(o.fading.compactMap(o.person))), 360),
            ("celebrations", AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(o.celebrations.prefix(12)) { c in CelebrationRow(c: c, person: c.people.first.flatMap(o.person)) }
            }.padding(16)), 360),
            ("settings", AnyView(SettingsSnapshot(o: o)), 520),
        ]
        if let p, case .success(let d) = Store.run(["ludia-person", p.id]), let det = try? Detail.decode(d) {
            pages.append(("person", AnyView(PersonSnapshot(p: p, d: det)), 760))
        }
        for (name, view, width) in pages {
            for dark in [false, true] {
                let v = view.environment(\.snapshot, true).frame(width: width).frame(minHeight: 300).background(dark ? Color(white: 0.12) : .white)
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

/// Lists render as a placeholder in ImageRenderer, so rows go in a plain stack.
private struct SnapRows: View {
    let people: [Person]
    init(_ p: [Person]) { people = p }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { ForEach(people) { PersonRow(p: $0); Divider() } }.padding(16)
    }
}

/// Lists render empty in ImageRenderer, so the snapshot draws rows in a plain stack.
private struct PersonSnapshot: View {
    let p: Person
    let d: Detail
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PersonHeader(p: p, store: .shared)
            LastContactCard(p: p)
            PromisesCard(p: p, promises: d.promises, store: .shared)
            DetailCards(p: p, d: d)
            ContactCard(p: p)
        }
        .padding(24)
    }
}

private struct SettingsSnapshot: View {
    let o: Overview
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Source.allCases) { s in SourceRow(s: s, mode: o.settings.sources[s.rawValue] ?? "off") { _ in } }
        }
        .padding(24)
    }
}
