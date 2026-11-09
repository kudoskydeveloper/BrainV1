import AppKit
import SwiftUI

/// `Hangar --render <out.png> [dark]`: draws the window's content into a PNG and quits, for checking the design.
@MainActor
enum RenderCheck {
    static func runIfAsked(_ apps: Apps) {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--render"), i + 1 < a.count else { return }
        let dark = a.count > i + 2 && a[i + 2] == "dark"
        let view = HangarView(apps: apps).frame(width: 380, height: 220)
            .background(dark ? Color(white: 0.16) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded(); host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[i + 1]))
        exit(0)
    }
}
