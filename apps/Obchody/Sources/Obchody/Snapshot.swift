import AppKit
import SwiftUI

/// `Obchody --snapshot <dir> [crm.json] [account.json]`: renders Dnes, rows and a client's detail to PNG (light and dark) and quits,
/// for checking the design without clicking through the app. Without files it asks Brain.
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let file = { (n: Int) in i + n < args.count ? try? Data(contentsOf: URL(fileURLWithPath: args[i + n])) : nil }
        var data = file(2) ?? Data()
        if data.isEmpty, case .success(let d) = Store.run(["crm"]) { data = d }
        guard let o = try? JSONDecoder().decode(Overview.self, from: data) else { print("decode failed"); exit(1) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pages: [(String, AnyView, CGFloat)] = [("today", AnyView(TodayView(data: o, query: "", pick: .constant(nil))), 860)]
        if let b = o.business("10t") {
            pages.append(("deals", AnyView(VStack(alignment: .leading, spacing: 8) { ForEach(b.deals.prefix(8)) { DealCard(b: b, d: $0) } }.frame(width: 260).padding(16)), 300))
        }
        if let k = o.business("kudosky") {
            pages.append(("leads", AnyView(VStack(alignment: .leading, spacing: 6) { ForEach(k.leads.prefix(10)) { LeadRow(l: $0); Divider() } }.padding(16)), 420))
        }
        if let a = file(3), let det = try? JSONDecoder().decode(AccountDetail.self, from: a) {
            pages.append(("account", AnyView(AccountDetailView(d: det, b: o.business(det.business))), 420))
        }
        for (name, view, width) in pages {
            for dark in [false, true] {
                let v = view.environment(\.snapshot, true).environmentObject(Editing()).frame(width: width).background(dark ? Color(white: 0.12) : .white)
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
