// Draws the BetterSpotlight app icon (a neutral glass magnifier) as a 1024 px PNG with plain Core Graphics.
// Usage: swift Scripts/make-icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")

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
// Flip to a top-left origin so the coordinates below read like a design file.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: 824 pt tile inside the 1024 canvas, ~185 pt continuous-ish corner radius.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft contact shadow under the tile (the only blur; it grounds the tile like system icons).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.28))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0xF4F4F6))
ctx.fillPath()
ctx.restoreGState()

// Hairline edge so the light tile holds up on light backgrounds.
ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(0x000000, 0.08))
ctx.setLineWidth(2)
ctx.strokePath()

// Magnifier geometry: lens up-left, handle toward bottom-right at 45°.
let center = CGPoint(x: 452, y: 452)
let radius: CGFloat = 196
let ring: CGFloat = 54
let graphite = rgb(0x2E2F33)

// Handle: a capsule from the ring's edge outward.
let angle = CGFloat.pi / 4
let start = CGPoint(x: center.x + cos(angle) * (radius + ring / 2 - 6), y: center.y + sin(angle) * (radius + ring / 2 - 6))
let end = CGPoint(x: center.x + cos(angle) * (radius + 230), y: center.y + sin(angle) * (radius + 230))
ctx.setLineCap(.round)
ctx.setStrokeColor(graphite)
ctx.setLineWidth(84)
ctx.move(to: start)
ctx.addLine(to: end)
ctx.strokePath()

// Lens glass: a flat, slightly cool tint — reads as glass against the neutral tile.
let lens = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
ctx.setFillColor(rgb(0xD9E3EC))
ctx.fillEllipse(in: lens)

// Specular highlight: one crescent arc on the upper-left, the cue that it is glass.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
ctx.setLineWidth(26)
ctx.setLineCap(.round)
ctx.addArc(center: center, radius: radius - 52, startAngle: .pi * 1.08, endAngle: .pi * 1.42, clockwise: false)
ctx.strokePath()

// Ring.
ctx.setStrokeColor(graphite)
ctx.setLineWidth(ring)
ctx.strokeEllipse(in: lens)

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("no image") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
