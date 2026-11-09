// Draws the Brain icon (1024 px PNG): purple-indigo rounded square, soft glow, white brain.head.profile symbol.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(red: 0.55, green: 0.33, blue: 0.98, alpha: 1).cgColor,
                             NSColor(red: 0.20, green: 0.16, blue: 0.62, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 380, options: [])
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let s = sym.size
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
sym.draw(in: CGRect(x: 512 - s.width / 2, y: 512 - s.height / 2, width: s.width, height: s.height))
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
