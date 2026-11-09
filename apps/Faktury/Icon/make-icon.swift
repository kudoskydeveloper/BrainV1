// Draws the Faktúry icon (1024 px PNG) in the same family as Brain, MarketBar, Hangar, Courier, Fitness and Meetingy: rounded
// square with a diagonal gradient (gold → deep amber), a soft glow and a white geometric invoice drawn with one stroke width:
// a sheet outline with its top right corner folded and two lines of text.
// Usage: swift make-icon.swift icon-1024.png
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
let top = NSColor(red: 1.00, green: 0.79, blue: 0.30, alpha: 1), bottom = NSColor(red: 0.86, green: 0.43, blue: 0.06, alpha: 1)
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 380, options: [])

// The mark in its own units (a 200 wide tile, y down, as in the SVG sketch), then scaled into the tile.
let w: CGFloat = 13                      // stroke width of every part
let s: CGFloat = 824 / 200
var t = CGAffineTransform(translationX: 100 - 10 * s, y: 924 + 10 * s).scaledBy(x: s, y: -s)
let mark = CGMutablePath()
let sheet = CGMutablePath()
sheet.addLines(between: [CGPoint(x: 66, y: 48), CGPoint(x: 128, y: 48), CGPoint(x: 154, y: 74), CGPoint(x: 154, y: 172), CGPoint(x: 66, y: 172)])
sheet.closeSubpath()
mark.addPath(sheet.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
let lines = CGMutablePath()
lines.addLines(between: [CGPoint(x: 128, y: 48), CGPoint(x: 128, y: 74), CGPoint(x: 154, y: 74)])   // the fold
lines.move(to: CGPoint(x: 88, y: 112)); lines.addLine(to: CGPoint(x: 132, y: 112))
lines.move(to: CGPoint(x: 88, y: 138)); lines.addLine(to: CGPoint(x: 118, y: 138))
mark.addPath(lines.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
// the folded flap is solid, so no sliver of gradient shows between the fold and the diagonal edge
let flap = CGMutablePath(); flap.addLines(between: [CGPoint(x: 128, y: 48), CGPoint(x: 154, y: 74), CGPoint(x: 128, y: 74)]); flap.closeSubpath()

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(mark.copy(using: &t)!); ctx.fillPath(using: .winding)
ctx.addPath(flap.copy(using: &t)!); ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
