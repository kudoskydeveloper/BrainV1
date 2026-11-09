import AppKit
import SwiftUI

/// `Meetings --snapshot <dir> [meetings.json]`: renders the lists and details to PNG (light and dark) and quits, for checking
/// the design without clicking through the app. Loads one meeting prep from Brain for the upcoming detail.
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let data: Data
        if i + 2 < args.count { data = (try? Data(contentsOf: URL(fileURLWithPath: args[i + 2]))) ?? Data() }
        else if case .success(let d) = Store.run(["meetings", "--days", "365"]) { data = d } else { data = Data() }
        guard let m = try? MeetingsData.decode(data) else { print("decode failed"); exit(1) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var pages: [(String, AnyView, CGFloat)] = [
            ("upcoming-list", AnyView(UpcomingList(items: m.upcoming, selection: .constant(nil)).environment(\.snapshot, true)), 380),
            ("recording-list", AnyView(RecordingList(items: m.recordings, selection: .constant(nil), title: "Nahrávky")), 380),
        ]
        if let r = m.recordings.max(by: { $0.sections.count < $1.sections.count }) { pages.append(("recording", AnyView(RecordingDetail(r: r)), 760)) }
        if let u = m.upcoming.first, case .success(let d) = Store.run(["meeting-prep", u.id]), let p = try? Prep.decode(d) {
            pages.append(("upcoming", AnyView(VStack(alignment: .leading, spacing: 16) { UpcomingHeaderSnapshot(u: u, p: p) }.padding(24)), 760))
        }
        for (name, view, width) in pages {
            for dark in [false, true] {
                let v = view.environment(\.snapshot, true).frame(width: width).background(dark ? Color(white: 0.12) : .white)
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

/// The upcoming detail without the store (the snapshot has its prep already).
private struct UpcomingHeaderSnapshot: View {
    let u: Upcoming
    let p: Prep
    var body: some View {
        Card("Účastníci", symbol: "person.2.fill", tint: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(u.people, id: \.self) { x in PersonRow(person: x, prep: p.people.first { $0.email == x.email }) }
            }
        }
        PrepView(p: p)
    }
}
