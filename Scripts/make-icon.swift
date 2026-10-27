// Draws the Hunch app icon as a 1024 px PNG with plain Core Graphics: a glass orb on a night tile with a four-point
// glint caught inside it (the moment a hunch lands). Usage: swift Scripts/make-icon.swift <out.png> [--mark]  (--mark: no tile, for docs)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "icon_1024.png")
let markOnly = args.contains("--mark")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no context") }
ctx.setShouldAntialias(true)
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

// macOS icon grid: 824 pt tile inside the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

if !markOnly {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x14151F))
    ctx.fillPath()
    ctx.restoreGState()

    // Night tile: deep ink, a little lighter at the top like light falling on it.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0x2A2C40, 1, 0), (0x15161F, 1, 0.55), (0x0C0D13, 1, 1)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Warm bloom behind the glint, so the light seems to come from it.
    ctx.drawRadialGradient(gradient([(0xFFB45C, 0.30, 0), (0xFF8A3D, 0.10, 0.45), (0xFF8A3D, 0, 1)]),
                           startCenter: CGPoint(x: 600, y: 420), startRadius: 0,
                           endCenter: CGPoint(x: 600, y: 420), endRadius: 460, options: [])
    ctx.restoreGState()

    // Inner top edge highlight (glass-tile rim).
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

// The pebble: a glass orb, centred.
let pebble = CGRect(x: 212, y: 212, width: 600, height: 600)
let pebblePath = CGPath(ellipseIn: pebble, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: rgb(0x000000, markOnly ? 0.25 : 0.55))
ctx.addPath(pebblePath)
ctx.setFillColor(rgb(0x3A3D55, 0.9))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(pebblePath)
ctx.clip()
// Body: cool glass, brighter toward the lit upper-right.
ctx.drawLinearGradient(gradient([(0xC9D3FF, 0.95, 0), (0x7A82B8, 0.85, 0.5), (0x3B3F63, 0.95, 1)]),
                       start: CGPoint(x: 660, y: 212), end: CGPoint(x: 330, y: 812), options: [])
// Warm light picked up from the glint.
ctx.drawRadialGradient(gradient([(0xFFD9A0, 0.75, 0), (0xFFB45C, 0.25, 0.4), (0xFFB45C, 0, 1)]),
                       startCenter: CGPoint(x: 598, y: 418), startRadius: 0,
                       endCenter: CGPoint(x: 598, y: 418), endRadius: 380, options: [])
// Bottom inner glow: light refracted through the glass.
ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.35, 0), (0xFFFFFF, 0, 1)]),
                       startCenter: CGPoint(x: 470, y: 800), startRadius: 0,
                       endCenter: CGPoint(x: 470, y: 800), endRadius: 300, options: [])
ctx.restoreGState()

// Rim: a bright hairline on the lit side.
ctx.saveGState()
ctx.addPath(pebblePath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
ctx.setLineWidth(5)
ctx.strokePath()
ctx.restoreGState()

// Soft secondary reflection, lower-left.
ctx.saveGState()
ctx.setStrokeColor(rgb(0xFFFFFF, 0.35))
ctx.setLineWidth(16)
ctx.setLineCap(.round)
let c = CGPoint(x: pebble.midX, y: pebble.midY)
ctx.addArc(center: c, radius: 236, startAngle: .pi * 0.62, endAngle: .pi * 0.86, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// The glint: a four-point star with concave sides, caught in the orb's upper-right, where the light lands.
func star(center p: CGPoint, long: CGFloat, short: CGFloat, pinch: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let tips = [CGPoint(x: p.x, y: p.y - long), CGPoint(x: p.x + short, y: p.y),
                CGPoint(x: p.x, y: p.y + long), CGPoint(x: p.x - short, y: p.y)]
    path.move(to: tips[0])
    for i in 0..<4 {
        let a = tips[i], b = tips[(i + 1) % 4]
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let ctrl = CGPoint(x: p.x + (mid.x - p.x) * pinch, y: p.y + (mid.y - p.y) * pinch)
        path.addQuadCurve(to: b, control: ctrl)
    }
    path.closeSubpath()
    return path
}
let g = CGPoint(x: 598, y: 418)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: rgb(0xFFC277, 0.95))
ctx.addPath(star(center: g, long: 150, short: 128, pinch: 0.16))
ctx.clip()
ctx.drawRadialGradient(gradient([(0xFFFFFF, 1, 0), (0xFFF1D6, 1, 0.35), (0xFFC277, 1, 1)]),
                       startCenter: g, startRadius: 0, endCenter: g, endRadius: 150, options: [])
ctx.restoreGState()
// Glow pass (clip removed the shadow): draw the star again with its halo.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xFFB45C, 0.9))
ctx.addPath(star(center: g, long: 150, short: 128, pinch: 0.16))
ctx.setFillColor(rgb(0xFFF6E6))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(star(center: g, long: 100, short: 86, pinch: 0.14))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("no image") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
