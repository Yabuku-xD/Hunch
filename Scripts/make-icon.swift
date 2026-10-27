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
ctx.interpolationQuality = .high
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

/// The macOS icon shape: straight edges joined by superellipse corners, so curvature eases in (continuous corners)
/// instead of jumping as a circular-arc rounded rect does.
func squircle(_ r: CGRect, radius: CGFloat = 236, exponent n: CGFloat = 4) -> CGPath {
    let path = CGMutablePath()
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: r.maxX - radius, y: r.minY + radius), -.pi / 2), (CGPoint(x: r.maxX - radius, y: r.maxY - radius), 0),
        (CGPoint(x: r.minX + radius, y: r.maxY - radius), .pi / 2), (CGPoint(x: r.minX + radius, y: r.minY + radius), .pi),
    ]
    for (i, (c, start)) in corners.enumerated() {
        for k in 0...90 {
            let t = start + CGFloat(k) / 90 * .pi / 2
            let (co, si) = (cos(t), sin(t))
            let p = CGPoint(
                x: c.x + radius * (co < 0 ? -1 : 1) * pow(abs(co), 2 / n),
                y: c.y + radius * (si < 0 ? -1 : 1) * pow(abs(si), 2 / n))
            i == 0 && k == 0 ? path.move(to: p) : path.addLine(to: p)
        }
    }
    path.closeSubpath()
    return path
}

/// Strokes `path` with a gradient running from `from` to `to` (a rim lit on one side).
func gradientStroke(_ path: CGPath, width: CGFloat, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}

// macOS icon grid: 824 pt tile inside the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile)

// The pebble: a glass orb, a little above centre so its caustic has room below.
let pebble = CGRect(x: 236, y: 220, width: 552, height: 552)
let pebblePath = CGPath(ellipseIn: pebble, transform: nil)
let g = CGPoint(x: 592, y: 420)  // the glint

if !markOnly {
    // Drop shadow: soft and low, like the system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000000, 0.38))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x14151F))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // Night tile: deep ink, lighter at the top like light falling on it.
    ctx.drawLinearGradient(
        gradient([(0x2E3046, 1, 0), (0x17182A, 1, 0.5), (0x0B0C14, 1, 1)]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Warm bloom from the glint.
    ctx.drawRadialGradient(
        gradient([(0xFFB45C, 0.26, 0), (0xFF8A3D, 0.08, 0.45), (0xFF8A3D, 0, 1)]),
        startCenter: g, startRadius: 0, endCenter: g, endRadius: 470, options: [])
    // Caustic: the orb focuses the glint's light into a warm pool on the tile below it.
    ctx.saveGState()
    ctx.translateBy(x: 536, y: 816)
    ctx.scaleBy(x: 1, y: 0.28)
    ctx.drawRadialGradient(
        gradient([(0xFFD49A, 0.42, 0), (0xFFB45C, 0.14, 0.5), (0xFFB45C, 0, 1)]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 250, options: [])
    ctx.restoreGState()
    // Contact shadow under the orb.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 782)
    ctx.scaleBy(x: 1, y: 0.16)
    ctx.drawRadialGradient(
        gradient([(0x000000, 0.55, 0), (0x000000, 0, 1)]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 250, options: [])
    ctx.restoreGState()
    // Top sheen: the glass tile catches light along its upper half.
    ctx.drawLinearGradient(
        gradient([(0xFFFFFF, 0.07, 0), (0xFFFFFF, 0, 0.35)]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // Tile rim: bright at the top edge, gone at the bottom.
    gradientStroke(
        tilePath, width: 4, gradient([(0xFFFFFF, 0.28, 0), (0xFFFFFF, 0.06, 0.5), (0xFFFFFF, 0.02, 1)]),
        from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
}

// Orb body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 44, color: rgb(0x000000, markOnly ? 0.25 : 0.5))
ctx.addPath(pebblePath)
ctx.setFillColor(rgb(0x3A3D55, 0.92))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(pebblePath)
ctx.clip()
// Cool glass, brighter toward the lit upper-right, deep at the lower-left.
ctx.drawLinearGradient(
    gradient([(0xD4DCFF, 0.96, 0), (0x8890C4, 0.9, 0.45), (0x3A3E66, 0.97, 0.85), (0x2A2D4C, 1, 1)]),
    start: CGPoint(x: 700, y: 220), end: CGPoint(x: 330, y: 772), options: [])
// Warm light picked up from the glint.
ctx.drawRadialGradient(
    gradient([(0xFFDCA8, 0.8, 0), (0xFFB45C, 0.28, 0.38), (0xFFB45C, 0, 1)]),
    startCenter: g, startRadius: 0, endCenter: g, endRadius: 360, options: [])
// Refraction: the bottom of the orb gathers light, as glass does opposite its light source.
ctx.drawRadialGradient(
    gradient([(0xFFE7C4, 0.42, 0), (0xFFFFFF, 0.12, 0.45), (0xFFFFFF, 0, 1)]),
    startCenter: CGPoint(x: 470, y: 760), startRadius: 0,
    endCenter: CGPoint(x: 470, y: 760), endRadius: 260, options: [])
// Edge darkening: thickness of the glass at its silhouette.
ctx.drawRadialGradient(
    gradient([(0x000000, 0, 0.78), (0x0A0B1A, 0.38, 1)]),
    startCenter: CGPoint(x: pebble.midX, y: pebble.midY), startRadius: 0,
    endCenter: CGPoint(x: pebble.midX, y: pebble.midY), endRadius: pebble.width / 2, options: [])
// Specular window: a soft crescent of reflected sky at the upper-left.
ctx.saveGState()
let spec = CGMutablePath()
spec.addEllipse(in: CGRect(x: 290, y: 262, width: 330, height: 220))
let cut = CGMutablePath()
cut.addEllipse(in: CGRect(x: 318, y: 318, width: 360, height: 260))
ctx.addPath(spec)
ctx.addPath(cut)
ctx.clip(using: .evenOdd)
ctx.addPath(spec)
ctx.clip()
ctx.drawLinearGradient(
    gradient([(0xFFFFFF, 0.62, 0), (0xFFFFFF, 0, 1)]),
    start: CGPoint(x: 360, y: 262), end: CGPoint(x: 470, y: 420), options: [])
ctx.restoreGState()
ctx.restoreGState()

// Rim: a hairline lit at the top-right, fading toward the lower-left.
gradientStroke(
    pebblePath, width: 5, gradient([(0xFFFFFF, 0.85, 0), (0xFFFFFF, 0.25, 0.55), (0xFFFFFF, 0.5, 1)]),
    from: CGPoint(x: 700, y: 220), to: CGPoint(x: 330, y: 772))

// The glint: a four-point star with concave sides, caught in the orb's upper-right, where the light lands.
func star(center p: CGPoint, long: CGFloat, short: CGFloat, pinch: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let tips = [
        CGPoint(x: p.x, y: p.y - long), CGPoint(x: p.x + short, y: p.y),
        CGPoint(x: p.x, y: p.y + long), CGPoint(x: p.x - short, y: p.y),
    ]
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
// Halo first, then the star body, then its white-hot core.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0xFFB45C, 0.95))
ctx.addPath(star(center: g, long: 156, short: 132, pinch: 0.16))
ctx.setFillColor(rgb(0xFFF1DC))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(star(center: g, long: 156, short: 132, pinch: 0.16))
ctx.clip()
ctx.drawRadialGradient(
    gradient([(0xFFFFFF, 1, 0), (0xFFF3DD, 1, 0.4), (0xFFC277, 1, 1)]),
    startCenter: g, startRadius: 0, endCenter: g, endRadius: 156, options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: rgb(0xFFFFFF, 0.9))
ctx.addPath(star(center: g, long: 96, short: 82, pinch: 0.14))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

guard let image = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("no image") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
