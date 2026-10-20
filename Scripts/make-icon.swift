#!/usr/bin/env swift

// Draws Resources/AppIcon.icns from the app's mark.
//
// The icon is the mark on an ink ground: a platter's grooves around a spindle,
// cut by one slot at three o'clock, with the outer groove's last stretch lit in
// signal. Each representation is drawn at its own size rather than downscaled, so
// the 16 and 32 point cuts keep a single heavier groove instead of collapsing
// into a disc.

import AppKit
import Foundation

struct Ink {
    static let ground = CGColor(srgbRed: 0x16 / 255, green: 0x19 / 255, blue: 0x1B / 255, alpha: 1)
    static let groove = CGColor(srgbRed: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF1 / 255, alpha: 1)
    static let signal = CGColor(srgbRed: 0x0E / 255, green: 0x6E / 255, blue: 0x70 / 255, alpha: 1)
}

/// The mark's geometry on a 24×24 grid, in grid units.
struct Mark {
    let grooves: [CGFloat]
    let stroke: CGFloat
    let spindle: CGFloat

    static let full = Mark(grooves: [5.5, 9.0], stroke: 1.75, spindle: 1.35)
    static let compact = Mark(grooves: [7.2], stroke: 2.4, spindle: 1.5)

    /// Half-width of the slot, and its bearing in degrees clockwise from twelve.
    var slot: CGFloat { 7 }
    var slotBearing: CGFloat { 90 }
}

func draw(size: Int) -> Data {
    let side = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // The body macOS lays an app icon into: an 824 square centred on 1024.
    let unit = side / 1024
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let radius = 185.4 * unit
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.setFillColor(Ink.ground)
    context.fillPath()

    let mark = size <= 32 ? Mark.compact : Mark.full
    let grid = body.width / 24
    let center = CGPoint(x: body.midX, y: body.midY)
    context.setLineWidth(mark.stroke * grid)
    context.setLineCap(.butt)

    func arc(radius: CGFloat, from startBearing: CGFloat, to endBearing: CGFloat, color: CGColor, width: CGFloat? = nil) {
        if let width { context.setLineWidth(width * grid) }
        let r = radius * grid
        // Bearings are measured clockwise from twelve o'clock; Core Graphics
        // measures counter-clockwise from three o'clock.
        let start = (90 - endBearing) * .pi / 180
        let end = (90 - startBearing) * .pi / 180
        let path = CGMutablePath()
        path.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: false)
        context.addPath(path)
        context.setStrokeColor(color)
        context.strokePath()
    }

    for groove in mark.grooves {
        arc(radius: groove,
            from: mark.slotBearing + mark.slot,
            to: mark.slotBearing + 360 - mark.slot,
            color: Ink.groove)
    }

    let spindleRadius = mark.spindle * grid
    context.setFillColor(Ink.groove)
    context.fillEllipse(in: CGRect(x: center.x - spindleRadius, y: center.y - spindleRadius,
                                   width: spindleRadius * 2, height: spindleRadius * 2))

    // The outer groove's last stretch is lit in the signal colour and ends at
    // the slot's edge, so the mark reads as a platter with one sector still live.
    let litFrom = size <= 32 ? 0.6 : 0.72
    let sweep = 360 - mark.slot * 2
    if let outer = mark.grooves.last {
        arc(radius: outer,
            from: mark.slotBearing + mark.slot + sweep * litFrom,
            to: mark.slotBearing + 360 - mark.slot,
            color: Ink.signal,
            width: mark.stroke)
    }

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (size, name) in entries {
    try draw(size: size).write(to: iconset.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
