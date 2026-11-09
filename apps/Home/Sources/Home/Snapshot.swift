import AppKit
import HomeCore
import SwiftUI

/// `Home --snapshot <dir>`: renders every page with demo data to PNG (light and dark) and quits. For checking the design
/// without clicking through the app (screen capture isn't permitted).
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store(demo: ())
        let pages: [(String, AnyView)] = [
            ("today", AnyView(TodayView())),
            ("tasks", AnyView(TasksView())),
            ("shopping", AnyView(ShoppingView())),
            ("plan", AnyView(PlanView())),
            ("devices", AnyView(DevicesView())),
            ("household", AnyView(HouseholdView())),
            ("signin", AnyView(SignInView().frame(height: 560))),
        ]
        for (name, view) in pages {
            for dark in [false, true] {
                let v = view
                    .environment(store).environment(Events.shared).environment(AppState.shared).environment(Devices(folder: nil))
                    .environment(\.snapshot, true)
                    .frame(width: 900)
                    .background(dark ? Color(white: 0.12) : .white)
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
