// Draws the Herald icon (1024 px PNG) in the same family as Courier, Ľudia and Fitness: rounded square with a diagonal
// gradient (raspberry → wine red, heraldic gules; no other Hangar app uses it), a soft glow and a white geometric mark
// drawn with one stroke width, cut straight: the herald's standard, a pole with a swallow-tailed banner and a ring for
// the seal.
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
                    colors: [NSColor(red: 0.94, green: 0.42, blue: 0.52, alpha: 1).cgColor,
                             NSColor(red: 0.49, green: 0.06, blue: 0.21, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 545), startRadius: 0, endCenter: CGPoint(x: 512, y: 545), endRadius: 380, options: [])

// The mark in the units of the sketch (Hangar/icon-ideas/herald-b-zastava.svg: a 200 wide tile at 10,10, y down), then
// scaled into the tile.
let w: CGFloat = 13                      // stroke width of every part
let s: CGFloat = 824 / 200
var t = CGAffineTransform(translationX: 100 - 10 * s, y: 924 + 13.5 * s).scaledBy(x: s, y: -s)   // 3.5 up: measured centre
// each part is filled on its own, so where parts overlap they join without a seam
var parts: [CGPath] = []
func stroke(_ path: CGPath) { parts.append(path.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10)) }
func line(_ points: [CGPoint]) { let p = CGMutablePath(); p.addLines(between: points); stroke(p) }
// the pole across the top
line([CGPoint(x: 50, y: 58), CGPoint(x: 170, y: 58)])
// the banner hanging from it, swallow-tailed (its sides start inside the pole)
line([CGPoint(x: 72, y: 58), CGPoint(x: 72, y: 164), CGPoint(x: 110, y: 140), CGPoint(x: 148, y: 164), CGPoint(x: 148, y: 58)])
// the seal: a ring in the upper half of the banner
stroke(CGPath(ellipseIn: CGRect(x: 110 - 17, y: 98 - 17, width: 34, height: 34), transform: nil))

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
for p in parts { ctx.addPath(p.copy(using: &t)!); ctx.fillPath() }
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
