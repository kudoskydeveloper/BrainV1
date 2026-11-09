// Draws the Scout icon (1024 px PNG) in the same family as Courier, Herald and Obchody: rounded square with a diagonal gradient
// (lime → green; no other Hangar app uses it), a soft glow and a white mark drawn with one stroke width: binoculars, two
// lenses under one bridge (the scout looking far for addresses).
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
                    colors: [NSColor(red: 0.78, green: 0.90, blue: 0.36, alpha: 1).cgColor,
                             NSColor(red: 0.25, green: 0.56, blue: 0.12, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 545), startRadius: 0, endCenter: CGPoint(x: 512, y: 545), endRadius: 380, options: [])

// The mark in the units of the sketch (Hangar/icon-ideas/scout-a-dalekohlad.svg: a 200 wide tile at 10,10, y down), then
// scaled into the tile.
let w: CGFloat = 13
let s: CGFloat = 824 / 200
var t = CGAffineTransform(translationX: 100 - 10 * s, y: 924 + 13 * s).scaledBy(x: s, y: -s)   // 3 up: measured centre
// each part is filled on its own, so where parts overlap they join without a seam
var parts: [CGPath] = []
func stroke(_ p: CGPath) { parts.append(p.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10)) }
// the two lenses
stroke(CGPath(ellipseIn: CGRect(x: 76 - 32, y: 126 - 32, width: 64, height: 64), transform: nil))
stroke(CGPath(ellipseIn: CGRect(x: 144 - 32, y: 126 - 32, width: 64, height: 64), transform: nil))
// the bridge over them, its corners rounded
let bridge = CGMutablePath()
bridge.move(to: CGPoint(x: 76, y: 94)); bridge.addLine(to: CGPoint(x: 76, y: 78))
bridge.addArc(tangent1End: CGPoint(x: 76, y: 68), tangent2End: CGPoint(x: 86, y: 68), radius: 10)
bridge.addLine(to: CGPoint(x: 134, y: 68))
bridge.addArc(tangent1End: CGPoint(x: 144, y: 68), tangent2End: CGPoint(x: 144, y: 78), radius: 10)
bridge.addLine(to: CGPoint(x: 144, y: 94))
stroke(bridge)

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
for p in parts { ctx.addPath(p.copy(using: &t)!); ctx.fillPath() }
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
