// Draws the Obchody icon (1024 px PNG) in the same family as Courier, Herald and Ľudia: rounded square with a diagonal gradient
// (tangerine → burnt orange; no other Hangar app uses it), a soft glow and a white mark drawn with one stroke width, cut
// straight: the O of Obchody as a ring open at the top right, with the pipeline board inside (three columns of falling height).
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
                    colors: [NSColor(red: 1.00, green: 0.71, blue: 0.37, alpha: 1).cgColor,
                             NSColor(red: 0.85, green: 0.31, blue: 0.10, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 545), startRadius: 0, endCenter: CGPoint(x: 512, y: 545), endRadius: 380, options: [])

// The mark in the units of the sketch (Hangar/icon-ideas/obchody-b-pipeline.svg: a 200 wide tile at 10,10, y down), then
// scaled into the tile.
let w: CGFloat = 13
let s: CGFloat = 824 / 200
var t = CGAffineTransform(translationX: 100 - 10 * s, y: 924 + 10 * s).scaledBy(x: s, y: -s)
// each part is filled on its own, so where parts overlap they join without a seam
var parts: [CGPath] = []
func stroke(_ p: CGPath) { parts.append(p.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10)) }
// the O of Obchody: a ring open at the top right, its ends cut straight (like Courier's)
let ring = CGMutablePath()
ring.addArc(center: CGPoint(x: 110, y: 110), radius: 58, startAngle: atan2(73.2 - 110, 146.8 - 110), endAngle: 0, clockwise: true)
stroke(ring)
// the board inside: three columns of falling height, standing on one line
for (x, top) in [(84.0, 92.0), (110.0, 104.0), (136.0, 118.0)] as [(CGFloat, CGFloat)] {
    let bar = CGMutablePath(); bar.move(to: CGPoint(x: x, y: top)); bar.addLine(to: CGPoint(x: x, y: 138)); stroke(bar)
}

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
for p in parts { ctx.addPath(p.copy(using: &t)!); ctx.fillPath() }
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
