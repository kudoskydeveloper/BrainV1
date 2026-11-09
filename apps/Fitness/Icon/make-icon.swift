// Draws the Fitness icon (1024 px PNG) in the same family as Brain, MarketBar, Courier and Meetingy: rounded square with a
// diagonal gradient (coral → red), a soft glow and a white geometric dumbbell drawn with one stroke width: a bar, a tall
// inner plate and a short outer plate on each side, all cut straight.
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
                    colors: [NSColor(red: 1.00, green: 0.45, blue: 0.38, alpha: 1).cgColor,
                             NSColor(red: 0.84, green: 0.12, blue: 0.27, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 380, options: [])
// The mark in its own units (a 200 wide tile, y down, as in the SVG sketch), then scaled into the tile.
let w: CGFloat = 13                      // stroke width of every part
let s: CGFloat = 824 / 200
var t = CGAffineTransform(translationX: 100 - 10 * s, y: 924 + 10 * s).scaledBy(x: s, y: -s)
let lines = CGMutablePath()
lines.addLines(between: [CGPoint(x: 74, y: 110), CGPoint(x: 146, y: 110)])            // bar
for x: CGFloat in [74, 146] { lines.move(to: CGPoint(x: x, y: 76)); lines.addLine(to: CGPoint(x: x, y: 144)) }   // inner plates
for x: CGFloat in [54, 166] { lines.move(to: CGPoint(x: x, y: 92)); lines.addLine(to: CGPoint(x: x, y: 128)) }   // outer plates
let mark = lines.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10)

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(mark.copy(using: &t)!); ctx.fillPath(using: .winding)
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
