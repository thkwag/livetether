// Draws the LiveTether app icon and writes it as a macOS app icon set.
//
// The icon is a camera lens on a dark body, lit by green and blue coating reflections, with the red
// light a webcam shows while it is in use. It carries no logo or lettering.
//
// Usage: swift scripts/make-app-icon.swift <AppIcon.appiconset directory>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

/// The macOS app icon shape: a square with continuous corners. The corner curve is the published
/// reconstruction of Apple's continuous rounded corners, which runs 1.528 radii along each edge.
func iconShape(in rect: CGRect, radius r: CGFloat) -> CGPath {
    let curve: [(to: (CGFloat, CGFloat), c1: (CGFloat, CGFloat), c2: (CGFloat, CGFloat))] = [
        ((0.63149399, 0.07491100), (1.08849296, 0), (0.86840694, 0)),
        ((0.07491100, 0.63149399), (0.37282392, 0.16905368), (0.16905368, 0.37282392)),
        ((0, 1.52866483), (0, 0.86840694), (0, 1.08849296)),
    ]
    // Each corner: its point, the direction of the edge arriving at it and of the edge leaving it.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    for (index, (corner, arriving, leaving)) in corners.enumerated() {
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(
                x: corner.x - along * r * arriving.dx + across * r * leaving.dx,
                y: corner.y - along * r * arriving.dy + across * r * leaving.dy
            )
        }
        let start = point(1.52866483, 0)
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        for segment in curve {
            path.addCurve(
                to: point(segment.to.0, segment.to.1),
                control1: point(segment.c1.0, segment.c1.1),
                control2: point(segment.c2.0, segment.c2.1)
            )
        }
    }
    path.closeSubpath()
    return path
}

/// Fills the stroke of `path` with a vertical gradient, for rim lights.
func strokeWithGradient(_ context: CGContext, _ path: CGPath, width: CGFloat, _ fill: CGGradient, from top: CGFloat, to bottom: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(width)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(fill, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    context.restoreGState()
}

/// Draws the icon on a 1024 × 1024 canvas, origin at the bottom left. Small renderings leave out
/// the fine detail that would only blur.
func drawIcon(_ context: CGContext, detailed: Bool) {
    let body = iconShape(in: CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185.4)

    // The body and its shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.5))
    context.addPath(body)
    context.setFillColor(color(0x0B0B0D))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    context.drawLinearGradient(
        gradient([(0, color(0x323338)), (0.55, color(0x16171A)), (1, color(0x070708))]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
    )
    // A faint green glow close behind the lens.
    let glow = CGPoint(x: 420, y: 600)
    context.drawRadialGradient(
        gradient([(0, color(0x2FBF71, 0.16)), (1, color(0x2FBF71, 0))]),
        startCenter: glow, startRadius: 0, endCenter: glow, endRadius: 360, options: []
    )
    context.restoreGState()
    strokeWithGradient(context, body, width: 5, gradient([(0, color(0xFFFFFF, 0.28)), (1, color(0xFFFFFF, 0))]), from: 924, to: 620)

    let lens = CGPoint(x: 512, y: 494)

    // Barrel.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.6))
    context.addEllipse(in: circle(lens, 300))
    context.setFillColor(color(0x1E1F23))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addEllipse(in: circle(lens, 300))
    context.clip()
    context.drawLinearGradient(
        gradient([(0, color(0x5A5B61)), (0.5, color(0x2B2C31)), (1, color(0x141518))]),
        start: CGPoint(x: lens.x - 212, y: lens.y + 212), end: CGPoint(x: lens.x + 212, y: lens.y - 212), options: []
    )
    context.restoreGState()
    strokeWithGradient(context, CGPath(ellipseIn: circle(lens, 298), transform: nil), width: 4, gradient([(0, color(0xFFFFFF, 0.45)), (1, color(0xFFFFFF, 0))]), from: lens.y + 300, to: lens.y - 120)

    // Focus ring grip.
    if detailed {
        context.saveGState()
        context.setStrokeColor(color(0x000000, 0.32))
        context.setLineWidth(5)
        context.setLineCap(.round)
        let ridges = 96
        for index in 0..<ridges {
            let angle = CGFloat(index) / CGFloat(ridges) * 2 * .pi
            context.move(to: CGPoint(x: lens.x + cos(angle) * 266, y: lens.y + sin(angle) * 266))
            context.addLine(to: CGPoint(x: lens.x + cos(angle) * 288, y: lens.y + sin(angle) * 288))
        }
        context.strokePath()
        context.restoreGState()
    }

    // Front of the lens and the bezel around the glass.
    context.saveGState()
    context.addEllipse(in: circle(lens, 256))
    context.clip()
    context.drawRadialGradient(
        gradient([(0, color(0x0C0D10)), (0.82, color(0x16171B)), (1, color(0x232429))]),
        startCenter: lens, startRadius: 0, endCenter: lens, endRadius: 256, options: []
    )
    context.restoreGState()
    context.addEllipse(in: circle(lens, 256))
    context.setStrokeColor(color(0x000000, 0.7))
    context.setLineWidth(6)
    context.strokePath()
    strokeWithGradient(context, CGPath(ellipseIn: circle(lens, 222), transform: nil), width: 12, gradient([(0, color(0x4A4B51)), (1, color(0x0D0E10))]), from: lens.y + 222, to: lens.y - 222)

    // Glass.
    let glassRadius: CGFloat = 214
    context.saveGState()
    context.addEllipse(in: circle(lens, glassRadius))
    context.clip()
    let core = CGPoint(x: lens.x - 26, y: lens.y + 26)
    context.drawRadialGradient(
        gradient([(0, color(0x10203A)), (0.55, color(0x070C18)), (1, color(0x020306))]),
        startCenter: core, startRadius: 0, endCenter: lens, endRadius: glassRadius, options: []
    )
    // Green coating reflection: a crescent along the upper left.
    context.saveGState()
    let crescent = CGMutablePath()
    crescent.addEllipse(in: circle(lens, 200))
    crescent.addEllipse(in: circle(CGPoint(x: lens.x + 30, y: lens.y - 34), 192))
    context.addPath(crescent)
    context.clip(using: .evenOdd)
    let greenCenter = CGPoint(x: lens.x - 120, y: lens.y + 130)
    context.drawRadialGradient(
        gradient([(0, color(0x5BF59A, 0.95)), (0.5, color(0x2FBF71, 0.6)), (1, color(0x2FBF71, 0))]),
        startCenter: greenCenter, startRadius: 0, endCenter: greenCenter, endRadius: 250, options: []
    )
    context.restoreGState()
    // Soft green bloom inside the glass.
    context.drawRadialGradient(
        gradient([(0, color(0x2FBF71, 0.35)), (1, color(0x2FBF71, 0))]),
        startCenter: greenCenter, startRadius: 0, endCenter: greenCenter, endRadius: 190, options: []
    )
    // Blue ring of an inner element.
    let ringCenter = CGPoint(x: lens.x + 8, y: lens.y - 6)
    context.drawRadialGradient(
        gradient([(0, color(0x2E6BFF, 0)), (0.5, color(0x3B7BFF, 0.6)), (1, color(0x2E6BFF, 0))]),
        startCenter: ringCenter, startRadius: 96, endCenter: ringCenter, endRadius: 162, options: []
    )
    // Inner element.
    context.addEllipse(in: circle(ringCenter, 74))
    context.setFillColor(color(0x040509))
    context.fillPath()
    context.addEllipse(in: circle(ringCenter, 74))
    context.setStrokeColor(color(0x5A6CA8, 0.55))
    context.setLineWidth(4)
    context.strokePath()
    // Magenta flare and the specular highlights.
    let magenta = CGPoint(x: lens.x + 50, y: lens.y - 44)
    context.drawRadialGradient(
        gradient([(0, color(0xF05AD2, 0.9)), (1, color(0xF05AD2, 0))]),
        startCenter: magenta, startRadius: 0, endCenter: magenta, endRadius: 30, options: []
    )
    let sparkle = CGPoint(x: lens.x - 64, y: lens.y + 66)
    context.drawRadialGradient(
        gradient([(0, color(0xFFFFFF, 0.95)), (0.35, color(0xE8F4FF, 0.55)), (1, color(0xFFFFFF, 0))]),
        startCenter: sparkle, startRadius: 0, endCenter: sparkle, endRadius: 46, options: []
    )
    context.saveGState()
    context.addEllipse(in: CGRect(x: lens.x - 180, y: lens.y + 20, width: 250, height: 170))
    context.clip()
    context.drawLinearGradient(
        gradient([(0, color(0xFFFFFF, 0.14)), (1, color(0xFFFFFF, 0))]),
        start: CGPoint(x: lens.x - 120, y: lens.y + 190), end: CGPoint(x: lens.x - 40, y: lens.y + 30), options: []
    )
    context.restoreGState()
    context.restoreGState()
    context.addEllipse(in: circle(lens, glassRadius))
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.setLineWidth(2)
    context.strokePath()

    // The light a webcam shows while it is in use.
    let light = CGPoint(x: 792, y: 806)
    context.drawRadialGradient(
        gradient([(0, color(0xFF3B30, 0.55)), (1, color(0xFF3B30, 0))]),
        startCenter: light, startRadius: 0, endCenter: light, endRadius: 64, options: []
    )
    context.drawRadialGradient(
        gradient([(0, color(0xFF8A80)), (0.6, color(0xF0362B)), (1, color(0xC21E16))]),
        startCenter: CGPoint(x: light.x - 5, y: light.y + 5), startRadius: 0, endCenter: light, endRadius: 21, options: []
    )
    if detailed {
        let glint = CGPoint(x: light.x - 6, y: light.y + 7)
        context.drawRadialGradient(
            gradient([(0, color(0xFFFFFF, 0.8)), (1, color(0xFFFFFF, 0))]),
            startCenter: glint, startRadius: 0, endCenter: glint, endRadius: 8, options: []
        )
    }
}

func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(context, detailed: pixels >= 64)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

guard CommandLine.arguments.count == 2 else {
    print("usage: swift scripts/make-app-icon.swift <AppIcon.appiconset directory>")
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var entries: [String] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try writePNG(render(pixels: points * scale), to: directory.appendingPathComponent(name))
            entries.append("""
                {
                  "filename" : "\(name)",
                  "idiom" : "mac",
                  "scale" : "\(scale)x",
                  "size" : "\(points)x\(points)"
                }
            """)
        }
    }
    let contents = """
    {
      "images" : [
    \(entries.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("Wrote \(entries.count) images to \(directory.path)")
} catch {
    print("Cannot write the icon set: \(error)")
    exit(1)
}
