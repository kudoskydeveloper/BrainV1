// Draws the Recepty icon (1024 px PNG) in the same family as Brain, Courier, Faktúry and Home: rounded square with a
// diagonal gradient (aqua → teal, a colour no other app in the family has), a soft glow and one white geometric mark
// drawn with one stroke width: a cooking pot (rounded body, two handles) under a low domed lid resting on the rim, with a
// round knob. The mark is centred by its real outline.
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
                    colors: [NSColor(red: 0.36, green: 0.88, blue: 0.80, alpha: 1).cgColor,
                             NSColor(red: 0.04, green: 0.48, blue: 0.56, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 380, options: [])

// The mark in its own units (y down), stroked with one width and cut straight (butt caps), like Courier and Faktúry.
let w: CGFloat = 30
func stroke(_ p: CGPath) -> CGPath { p.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10) }
let mark = CGMutablePath()

// body: a rounded box
mark.addPath(stroke(CGPath(roundedRect: CGRect(x: -104, y: -10, width: 208, height: 140), cornerWidth: 42, cornerHeight: 42, transform: nil)))
// handles: short bars out of both sides, a little below the rim
for x: CGFloat in [-104, 104] {
    let h = CGMutablePath(); h.addLines(between: [CGPoint(x: x, y: 30), CGPoint(x: x + (x < 0 ? -40 : 40), y: 30)])
    mark.addPath(stroke(h))
}
// lid: a low dome resting on the rim, a little wider than the pot, with a round knob on top
let half: CGFloat = 130, foot: CGFloat = -10 - w + 2, rise: CGFloat = 22      // ends sit on the rim, apex `rise` higher
let radius = (half * half + rise * rise) / (2 * rise)
let centre = CGPoint(x: 0, y: foot - rise + radius)
let side = atan2(foot - centre.y, half)
let dome = CGMutablePath()
dome.addArc(center: centre, radius: radius, startAngle: .pi - side, endAngle: side, clockwise: false)
mark.addPath(stroke(dome))
let apex = foot - rise
mark.addEllipse(in: CGRect(x: -20, y: apex - w / 2 - 32, width: 40, height: 40))

// Scale so the mark is about 540 px at its widest and centre it by its outline.
let box = mark.boundingBoxOfPath
let s = 540 / max(box.width, box.height)
var t = CGAffineTransform(translationX: 512 - box.midX * s, y: 512 + box.midY * s).scaledBy(x: s, y: -s)

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(mark.copy(using: &t)!); ctx.fillPath(using: .winding)
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
