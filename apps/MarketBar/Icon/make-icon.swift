// Draws the MarketBar icon (1024 px PNG) in the same family as Brain, Courier, Fitness and Meetingy: rounded square with a
// diagonal gradient (emerald → deep teal), a soft glow and a white geometric mark drawn with one stroke width: a rising
// sparkline that ends in a ring, the live price.
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
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(red: 0.20, green: 0.84, blue: 0.56, alpha: 1).cgColor,
                             NSColor(red: 0.04, green: 0.36, blue: 0.42, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 380, options: [])

// The mark in its own units (a 200 wide tile, y down, as in the SVG sketch), then scaled into the tile.
let w: CGFloat = 13                      // stroke width of every part
let s: CGFloat = 824 / 200
var t = CGAffineTransform(translationX: 100 - 10 * s, y: 924 + 10 * s).scaledBy(x: s, y: -s)
let line = CGMutablePath()
line.addLines(between: [CGPoint(x: 44, y: 152), CGPoint(x: 82, y: 114), CGPoint(x: 106, y: 136), CGPoint(x: 150, y: 92)])
let mark = CGMutablePath()
mark.addPath(line.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
let price = CGPath(ellipseIn: CGRect(x: 149, y: 67, width: 26, height: 26), transform: nil)
mark.addPath(price.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10))

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(mark.copy(using: &t)!); ctx.fillPath(using: .winding)
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
