import AppKit
import FinancieCore
import SwiftUI

/// `Financie --demo <dir> --snapshot <out>`: renders the overview pages to PNG (light and dark) and quits, for checking the
/// design without clicking through the app (lists render empty in an image, so only the overviews).
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel.shared
        var pages: [(String, AnyView)] = [("overview", AnyView(OverviewPage(model: m, scope: .all)))]
        for w in m.wallets { pages.append(("wallet-\(w.id)", AnyView(OverviewPage(model: m, scope: Scope(walletId: w.id), title: w.name)))) }
        for (name, view) in pages {
            for dark in [false, true] {
                let v = view.environment(\.snapshot, true).frame(width: 1000).background(dark ? Color(white: 0.12) : .white)
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
