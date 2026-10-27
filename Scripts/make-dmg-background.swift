// Draws the DMG window background (660 × 400 pt) at 1x and 2x: a pale pearl gradient, a frosted glass card under
// each icon and an arrow from Hunch to Applications. Finder draws icon labels in black over a background picture in
// both appearances, so the background stays light. Usage: swift Scripts/make-dmg-background.swift <out-dir>
// Writes background.png and background@2x.png; Scripts/make-dmg.sh joins them into one HiDPI TIFF.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width: CGFloat = 660
let height: CGFloat = 400
/// Icon centres in window points, top-left origin; Scripts/make-dmg.sh places the icons at the same spots.
let appCentre = CGPoint(x: 180, y: 176)
let linkCentre = CGPoint(x: 480, y: 176)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

func render(scale: CGFloat, to url: URL) {
    let w = Int(width * scale)
    let h = Int(height * scale)
    guard
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    ctx.interpolationQuality = .high
    // Top-left origin in points, like Finder's icon coordinates.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)

    // Pearl: near-white at the top, a cool lilac grey at the bottom.
    ctx.drawLinearGradient(
        gradient([(0xFAFAFD, 1, 0), (0xEEEFF6, 1, 0.55), (0xE2E3EE, 1, 1)]),
        start: .zero, end: CGPoint(x: 0, y: height), options: [])
    // Warm bloom behind the app (the icon's glint), cool light behind Applications.
    ctx.drawRadialGradient(
        gradient([(0xFFB45C, 0.20, 0), (0xFFB45C, 0.06, 0.5), (0xFFB45C, 0, 1)]),
        startCenter: appCentre, startRadius: 0, endCenter: appCentre, endRadius: 240, options: [])
    ctx.drawRadialGradient(
        gradient([(0x7F9CFF, 0.16, 0), (0x7F9CFF, 0.05, 0.5), (0x7F9CFF, 0, 1)]),
        startCenter: linkCentre, startRadius: 0, endCenter: linkCentre, endRadius: 240, options: [])

    // Glass cards: a faint rounded card under each icon and its label, with a rim lit from above.
    for c in [appCentre, linkCentre] {
        let r = CGRect(x: c.x - 92, y: c.y - 86, width: 184, height: 200)
        let card = CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: rgb(0x23264A, 0.12))
        ctx.addPath(card)
        ctx.setFillColor(rgb(0xFFFFFF, 0.5))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(card)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0xFFFFFF, 0.45, 0), (0xFFFFFF, 0.1, 1)]), start: CGPoint(x: c.x, y: r.minY),
            end: CGPoint(x: c.x, y: r.maxY), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.setLineWidth(1)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0xFFFFFF, 1, 0), (0xC9CBDA, 0.7, 1)]), start: CGPoint(x: c.x, y: r.minY),
            end: CGPoint(x: c.x, y: r.maxY), options: [])
        ctx.restoreGState()
    }

    // Arrow: three chevrons fading in toward Applications.
    let mid = (appCentre.x + linkCentre.x) / 2
    for (i, alpha) in [0.18, 0.36, 0.62].enumerated() {
        let x = mid - 22 + CGFloat(i) * 18
        ctx.move(to: CGPoint(x: x - 6, y: appCentre.y - 11))
        ctx.addLine(to: CGPoint(x: x + 5, y: appCentre.y))
        ctx.addLine(to: CGPoint(x: x - 6, y: appCentre.y + 11))
        ctx.setStrokeColor(rgb(0x2A2C42, alpha))
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // Caption.
    let font = CTFontCreateUIFontForLanguage(.system, 13, nil)!
    let text = NSAttributedString(
        string: "Drag Hunch to Applications",
        attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x2A2C42, 0.55),
        ])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: 340)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
render(scale: 1, to: dir.appendingPathComponent("background.png"))
render(scale: 2, to: dir.appendingPathComponent("background@2x.png"))
