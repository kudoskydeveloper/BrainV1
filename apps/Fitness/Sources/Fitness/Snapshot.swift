import AppKit
import SwiftUI

/// `Fitness --snapshot <dir> [overview.json]`: renders every page to PNG (light and dark) and quits. For checking the design
/// without clicking through the app.
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let json = i + 2 < args.count ? URL(fileURLWithPath: args[i + 2]) : nil
        let data: Data
        if let json { data = (try? Data(contentsOf: json)) ?? Data() } else if case .success(let d) = Store.run(days: 30) { data = d } else { data = Data() }
        guard let o = try? Overview.decode(data) else { print("decode failed"); exit(1) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pages: [(String, AnyView)] = [
            ("summary", AnyView(SummaryView(o: o, section: .constant(.summary)))),
            ("strength", AnyView(StrengthView(o: o))),
            ("nutrition", AnyView(NutritionView(o: o))),
            ("weight", AnyView(WeightView(o: o))),
        ]
        for s in o.sports where s.sport != .strength { pages.append(("sport-\(s.key)", AnyView(SportView(o: o, sport: s.sport)))) }
        if let e = o.strength.exercises.first(where: \.weighted) { pages.append(("exercise", AnyView(ExerciseView(e: e)))) }
        for (name, view) in pages {
            for dark in [false, true] {
                let v = view.environment(\.snapshot, true).frame(width: 900).background(dark ? Color(white: 0.12) : .white)
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
