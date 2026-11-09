// The iPhone variant of make-icon.swift: the same tile, full bleed (no margin, square corners, no alpha needed), because
// iOS draws its own rounded mask and fills transparent pixels with black. Usage: swift make-icon-ios.swift icon.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let shape = CGPath(roundedRect: rect, cornerWidth: 0, cornerHeight: 0, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(red: 0.30, green: 0.74, blue: 1.00, alpha: 1).cgColor,
                             NSColor(red: 0.07, green: 0.28, blue: 0.86, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 472, options: [])

// The mark in its own units (eye centre at 0,0, y down, about 256 wide), then scaled into the tile.
let w: CGFloat = 26                      // stroke width of every part
let s: CGFloat = 2.1 * 1024 / 824
var t = CGAffineTransform(translationX: 512 - 6 * s, y: 512 - 12 * 1024 / 824).scaledBy(x: s, y: -s)
let deg = { (d: CGFloat) in d * .pi / 180 }
let mark = CGMutablePath()
// neck and mane: the left half of a big ring, cut straight at the vertical axis
let neck = CGMutablePath(); neck.addArc(center: .zero, radius: 109, startAngle: deg(90), endAngle: deg(270), clockwise: false)
mark.addPath(neck.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
// the eye: a small ring open at the top left
let eye = CGMutablePath(); eye.addArc(center: .zero, radius: 37, startAngle: deg(-60), endAngle: deg(240), clockwise: false)
let eyeRing = eye.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
// muzzle: forehead line out to the nose, down the nose, back under the eye
let muzzle = CGMutablePath()
muzzle.addLines(between: [CGPoint(x: -20, y: -90), CGPoint(x: 117, y: -8), CGPoint(x: 97, y: 55), CGPoint(x: 0, y: 0)])
let band = muzzle.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .miter, miterLimit: 10)

ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(mark.copy(using: &t)!); ctx.fillPath()
// the muzzle starts at the vertical axis (like the neck ends there) and keeps the eye open
let hole = CGPath(ellipseIn: CGRect(x: -37 + w / 2, y: -37 + w / 2, width: 74 - w, height: 74 - w), transform: nil)
ctx.saveGState()
let clip = CGMutablePath()
clip.addLines(between: [CGPoint(x: 0, y: -300), CGPoint(x: 400, y: -300), CGPoint(x: 400, y: 300), CGPoint(x: -300, y: 300),
                        CGPoint(x: -300, y: -37 + w / 2), CGPoint(x: 0, y: -37 + w / 2)]); clip.closeSubpath()
clip.addPath(hole)
ctx.addPath(clip.copy(using: &t)!); ctx.clip(using: .evenOdd)
ctx.addPath(band.copy(using: &t)!); ctx.fillPath()
ctx.restoreGState()
// the eye's right end is cut along the muzzle's upper edge, so the two join without a step
let len: CGFloat = (97 * 97 + 55 * 55).squareRoot(); let d = CGPoint(x: 97 / len, y: 55 / len)
let edgeY = { (x: CGFloat) in (x * d.y) / d.x - w / 2 / d.x }   // upper edge of the lower muzzle line
ctx.saveGState()
let eyeClip = CGMutablePath()
eyeClip.addLines(between: [CGPoint(x: -300, y: -300), CGPoint(x: 0, y: -300), CGPoint(x: 0, y: edgeY(0)), CGPoint(x: 400, y: edgeY(400)),
                           CGPoint(x: 400, y: 300), CGPoint(x: -300, y: 300)]); eyeClip.closeSubpath()
ctx.addPath(eyeClip.copy(using: &t)!); ctx.clip()
ctx.addPath(eyeRing.copy(using: &t)!); ctx.fillPath()
ctx.restoreGState()
ctx.endTransparencyLayer()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
