#!/usr/bin/env swift
// Draws the BruTV app icon and writes every size the iOS asset catalog needs.
//
// Usage: swift tools/make-app-icon.swift [appiconset-dir]
//
// App Store Connect rejects the 1024 icon when it is not exactly 1024x1024
// or when it has an alpha channel, so every PNG is written opaque.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "mobile/ios/BruTV/BruTV/Resources/Assets.xcassets/AppIcon.appiconset"

let sizes = [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]
let canvas: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

/// A triangle with rounded corners, pointing right.
func roundedTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let mid = CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2)
    path.move(to: mid)
    path.addArc(tangent1End: a, tangent2End: b, radius: radius)
    path.addArc(tangent1End: b, tangent2End: c, radius: radius)
    path.addArc(tangent1End: c, tangent2End: a, radius: radius)
    path.closeSubpath()
    return path
}

func drawIcon(in ctx: CGContext) {
    // The drawing uses a top-left origin, like the design coordinates.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // Background: deep navy, lighter toward the top right.
    ctx.drawLinearGradient(
        gradient([color(0x0A0E19), color(0x121A2E), color(0x1A2542)], [0, 0.55, 1]),
        start: CGPoint(x: 0, y: canvas), end: CGPoint(x: canvas, y: 0), options: []
    )
    // Soft glow behind the signal arcs and the top of the TV.
    ctx.drawRadialGradient(
        gradient([color(0x2E5A7A, 0.55), color(0x2E5A7A, 0)]),
        startCenter: CGPoint(x: 512, y: 300), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 300), endRadius: 420, options: []
    )

    let tv = CGRect(x: 172, y: 290, width: 680, height: 520)
    let tvRadius: CGFloat = 84
    let lineWidth: CGFloat = 18

    // Stand, drawn first so the frame overlaps its top edge.
    let stand = CGMutablePath()
    stand.move(to: CGPoint(x: 442, y: tv.maxY - 4))
    stand.addLine(to: CGPoint(x: 582, y: tv.maxY - 4))
    stand.addLine(to: CGPoint(x: 616, y: 880))
    stand.addLine(to: CGPoint(x: 408, y: 880))
    stand.closeSubpath()
    ctx.addPath(stand)
    ctx.setFillColor(color(0x283A5E))
    ctx.fillPath()

    // Screen fill.
    let screen = CGPath(roundedRect: tv, cornerWidth: tvRadius, cornerHeight: tvRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x1A2A3E), color(0x141D30)]),
        start: CGPoint(x: tv.minX, y: tv.minY), end: CGPoint(x: tv.maxX, y: tv.maxY), options: []
    )
    ctx.restoreGState()

    // Frame glow.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 48, color: color(0x4AB0E8, 0.65))
    ctx.addPath(screen)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(color(0x4A9AE0))
    ctx.strokePath()
    ctx.restoreGState()

    // Frame stroke with a cyan to blue gradient.
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.setLineWidth(lineWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x62CDEB), color(0x3F86D8), color(0x2F5CC2)], [0, 0.5, 1]),
        start: CGPoint(x: tv.minX, y: tv.minY), end: CGPoint(x: tv.maxX, y: tv.maxY), options: []
    )
    ctx.restoreGState()

    // Signal arcs above the TV.
    let arcCenter = CGPoint(x: 512, y: 302)
    let arcs: [(radius: CGFloat, alpha: CGFloat)] = [(56, 1.0), (106, 0.72), (156, 0.45)]
    ctx.setLineCap(.round)
    ctx.setLineWidth(14)
    for arc in arcs {
        ctx.setStrokeColor(color(0x56B4DA, arc.alpha))
        // Angles are measured in the flipped space, so -90 degrees points up.
        ctx.addArc(
            center: arcCenter, radius: arc.radius,
            startAngle: (-90 - 32) * .pi / 180, endAngle: (-90 + 32) * .pi / 180, clockwise: false
        )
        ctx.strokePath()
    }

    // Play glyph, centered on its visual center inside the screen.
    let playCenterY = tv.midY
    let play = roundedTriangle(
        CGPoint(x: 458, y: playCenterY - 100),
        CGPoint(x: 630, y: playCenterY),
        CGPoint(x: 458, y: playCenterY + 100),
        radius: 26
    )
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0x7FDDF7, 0.45))
    ctx.addPath(play)
    ctx.setFillColor(color(0xBFEFFC))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(play)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xF2FBFF), color(0x86E0F8)]),
        start: CGPoint(x: 458, y: playCenterY - 100), end: CGPoint(x: 630, y: playCenterY + 60), options: []
    )
    ctx.restoreGState()
}

func makeContext(_ pixels: Int) -> CGContext {
    CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("could not write \(path)")
    }
}

let master = makeContext(Int(canvas))
master.interpolationQuality = .high
drawIcon(in: master)
let masterImage = master.makeImage()!

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
for size in sizes {
    let image: CGImage
    if size == Int(canvas) {
        image = masterImage
    } else {
        let ctx = makeContext(size)
        ctx.interpolationQuality = .high
        ctx.draw(masterImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        image = ctx.makeImage()!
    }
    writePNG(image, to: "\(outputDir)/AppIcon\(size).png")
    print("AppIcon\(size).png \(image.width)x\(image.height)")
}
