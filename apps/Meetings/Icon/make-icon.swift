// Draws the Meetingy icon (1024 px PNG) in the same family as Brain, MarketBar and Courier: rounded square with a diagonal
// gradient (teal → blue), a soft glow and a white geometric mark drawn with one stroke width: two people side by side,
// each a small ring for the head over a half-ring arch for the shoulders; the two arches together read as an M.
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
                    colors: [NSColor(red: 0.31, green: 0.82, blue: 0.91, alpha: 1).cgColor,
                             NSColor(red: 0.12, green: 0.36, blue: 0.85, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 545), startRadius: 0, endCenter: CGPoint(x: 512, y: 545), endRadius: 380, options: [])

// The mark in its own units (a 200 wide tile, y down, as in the SVG sketch), then scaled into the tile.
let w: CGFloat = 13                      // stroke width of every part
let s: CGFloat = 824 / 200
var t = CGAffineTransform(translationX: 100 - 10 * s, y: 924 + 10 * s).scaledBy(x: s, y: -s)
let mark = CGMutablePath()
for x: CGFloat in [85, 135] {
    // shoulders: the upper half of a ring, cut flat at the bottom (y grows down here, so the top half runs π → 2π)
    let arch = CGMutablePath(); arch.addArc(center: CGPoint(x: x, y: 150), radius: 28, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    mark.addPath(arch.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
    // head: a full ring
    let head = CGPath(ellipseIn: CGRect(x: x - 13, y: 77, width: 26, height: 26), transform: nil)
    mark.addPath(head.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
}

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(mark.copy(using: &t)!); ctx.fillPath(using: .winding)
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
