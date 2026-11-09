import AppKit
import ReceptyCore
import SwiftUI

/// `Recepty --demo <dir> --snapshot <out>`: renders the pages to PNG (light and dark) and quits, for checking the design
/// without clicking through the app.
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel.shared
        var pages: [(String, CGFloat, AnyView)] = [("library", 1100, AnyView(LibraryGrid(model: m)))]
        for r in m.recipes.prefix(3) { pages.append(("recipe-\(r.id)", 1100, AnyView(RecipePage(model: m, recipe: r)))) }
        if let r = m.recipes.first { pages.append(("cook", 1100, AnyView(CookView(recipe: r).frame(height: 700)))) }
        pages.append(("plan", 900, AnyView(PlanPage(model: m))))
        pages.append(("log", 900, AnyView(LogPage(model: m))))
        pages.append(("shopping", 820, AnyView(ShoppingPage(model: m))))
        for (name, width, view) in pages {
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

/// The library without the search field (an image can't show the toolbar).
struct LibraryGrid: View {
    @ObservedObject var model: AppModel
    var body: some View { LibraryContent(model: model, title: "Recepty", list: model.recipes) }
}
