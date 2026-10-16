#!/usr/bin/env swift
// Generates the tvOS brand assets (App Icon - Large, App Icon - Small, Top Shelf Image, Top Shelf Image Wide)
// with proper layered image stacks for Siri Remote 3D parallax and App Store Connect delivery.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let targetDir = repoRoot.appendingPathComponent("mobile/ios/BruTV/BruTV/Resources/Assets.xcassets/TVAppIcon.brandassets")

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

func drawBackground(in ctx: CGContext, width: CGFloat, height: CGFloat) {
    ctx.drawLinearGradient(
        gradient([color(0x0A0E19), color(0x121A2E), color(0x1A2542)], [0, 0.55, 1]),
        start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: []
    )
    ctx.drawRadialGradient(
        gradient([color(0x2E5A7A, 0.55), color(0x2E5A7A, 0)]),
        startCenter: CGPoint(x: width / 2, y: height * 0.35), startRadius: 0,
        endCenter: CGPoint(x: width / 2, y: height * 0.35), endRadius: max(width, height) * 0.5, options: []
    )
}

func drawForegroundLogo(in ctx: CGContext, centerX: CGFloat, centerY: CGFloat, scale: CGFloat) {
    // Logo native coordinate system: centered around (512, 512) on a 1024x1024 canvas
    ctx.saveGState()
    ctx.translateBy(x: centerX, y: centerY)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -512, y: -512)

    let tv = CGRect(x: 172, y: 290, width: 680, height: 520)
    let tvRadius: CGFloat = 84
    let lineWidth: CGFloat = 18

    // Stand
    let stand = CGMutablePath()
    stand.move(to: CGPoint(x: 442, y: tv.maxY - 4))
    stand.addLine(to: CGPoint(x: 582, y: tv.maxY - 4))
    stand.addLine(to: CGPoint(x: 616, y: 880))
    stand.addLine(to: CGPoint(x: 408, y: 880))
    stand.closeSubpath()
    ctx.addPath(stand)
    ctx.setFillColor(color(0x283A5E))
    ctx.fillPath()

    // Screen fill
    let screen = CGPath(roundedRect: tv, cornerWidth: tvRadius, cornerHeight: tvRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x1A2A3E), color(0x141D30)]),
        start: CGPoint(x: tv.minX, y: tv.minY), end: CGPoint(x: tv.maxX, y: tv.maxY), options: []
    )
    ctx.restoreGState()

    // Frame glow
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 48, color: color(0x4AB0E8, 0.65))
    ctx.addPath(screen)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(color(0x4A9AE0))
    ctx.strokePath()
    ctx.restoreGState()

    // Frame stroke gradient
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

    // Signal arcs
    let arcCenter = CGPoint(x: 512, y: 302)
    let arcs: [(radius: CGFloat, alpha: CGFloat)] = [(56, 1.0), (106, 0.72), (156, 0.45)]
    ctx.setLineCap(.round)
    ctx.setLineWidth(14)
    for arc in arcs {
        ctx.setStrokeColor(color(0x56B4DA, arc.alpha))
        ctx.addArc(
            center: arcCenter, radius: arc.radius,
            startAngle: (-90 - 32) * .pi / 180, endAngle: (-90 + 32) * .pi / 180, clockwise: false
        )
        ctx.strokePath()
    }

    // Play glyph
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

    ctx.restoreGState()
}

func makeOpaqueContext(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func makeTransparentContext(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Failed to write PNG at \(url.path)")
    }
}

func writeJSON(_ object: Any, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

// 1. Root TVAppIcon.brandassets/Contents.json
writeJSON([
    "assets": [
        [
            "filename": "Top Shelf Image.imageset",
            "role": "top-shelf-image",
            "size": "1920x720",
            "idiom": "tv"
        ],
        [
            "filename": "Top Shelf Image Wide.imageset",
            "role": "top-shelf-image-wide",
            "size": "2320x720",
            "idiom": "tv"
        ],
        [
            "filename": "App Icon - Small.imagestack",
            "role": "primary-app-icon",
            "size": "400x240",
            "idiom": "tv"
        ],
        [
            "filename": "App Icon - Large.imagestack",
            "role": "primary-app-icon",
            "size": "1280x768",
            "idiom": "tv"
        ]
    ],
    "info": [
        "version": 1,
        "author": "xcode"
    ]
], to: targetDir.appendingPathComponent("Contents.json"))

// 2. App Icon - Large (1280x768)
let largeStackDir = targetDir.appendingPathComponent("App Icon - Large.imagestack")
writeJSON([
    "layers": [
        ["filename": "Front.imagestacklayer"],
        ["filename": "Back.imagestacklayer"]
    ],
    "info": ["version": 1, "author": "xcode"]
], to: largeStackDir.appendingPathComponent("Contents.json"))

// Large Back (opaque)
let largeBackCtx = makeOpaqueContext(width: 1280, height: 768)
largeBackCtx.translateBy(x: 0, y: 768)
largeBackCtx.scaleBy(x: 1, y: -1)
drawBackground(in: largeBackCtx, width: 1280, height: 768)
let largeBackImg = largeBackCtx.makeImage()!
let largeBackLayer = largeStackDir.appendingPathComponent("Back.imagestacklayer")
writeJSON(["info": ["version": 1, "author": "xcode"]], to: largeBackLayer.appendingPathComponent("Contents.json"))
let largeBackImgSet = largeBackLayer.appendingPathComponent("Content.imageset")
writeJSON([
    "images": [
        ["filename": "back-1280x768.png", "idiom": "tv", "scale": "1x"]
    ],
    "info": ["version": 1, "author": "xcode"]
], to: largeBackImgSet.appendingPathComponent("Contents.json"))
writePNG(largeBackImg, to: largeBackImgSet.appendingPathComponent("back-1280x768.png"))

// Large Front (transparent background + floating logo)
let largeFrontCtx = makeTransparentContext(width: 1280, height: 768)
largeFrontCtx.translateBy(x: 0, y: 768)
largeFrontCtx.scaleBy(x: 1, y: -1)
drawForegroundLogo(in: largeFrontCtx, centerX: 640, centerY: 384, scale: 0.68)
let largeFrontImg = largeFrontCtx.makeImage()!
let largeFrontLayer = largeStackDir.appendingPathComponent("Front.imagestacklayer")
writeJSON(["info": ["version": 1, "author": "xcode"]], to: largeFrontLayer.appendingPathComponent("Contents.json"))
let largeFrontImgSet = largeFrontLayer.appendingPathComponent("Content.imageset")
writeJSON([
    "images": [
        ["filename": "front-1280x768.png", "idiom": "tv", "scale": "1x"]
    ],
    "info": ["version": 1, "author": "xcode"]
], to: largeFrontImgSet.appendingPathComponent("Contents.json"))
writePNG(largeFrontImg, to: largeFrontImgSet.appendingPathComponent("front-1280x768.png"))

// 3. App Icon - Small (400x240 @1x, 800x480 @2x)
let smallStackDir = targetDir.appendingPathComponent("App Icon - Small.imagestack")
writeJSON([
    "layers": [
        ["filename": "Front.imagestacklayer"],
        ["filename": "Back.imagestacklayer"]
    ],
    "info": ["version": 1, "author": "xcode"]
], to: smallStackDir.appendingPathComponent("Contents.json"))

// Small Back
let smallBackLayer = smallStackDir.appendingPathComponent("Back.imagestacklayer")
writeJSON(["info": ["version": 1, "author": "xcode"]], to: smallBackLayer.appendingPathComponent("Contents.json"))
let smallBackImgSet = smallBackLayer.appendingPathComponent("Content.imageset")
writeJSON([
    "images": [
        ["filename": "back-400x240.png", "idiom": "tv", "scale": "1x"],
        ["filename": "back-800x480.png", "idiom": "tv", "scale": "2x"]
    ],
    "info": ["version": 1, "author": "xcode"]
], to: smallBackImgSet.appendingPathComponent("Contents.json"))

for (w, h, scaleName) in [(400, 240, "400x240"), (800, 480, "800x480")] {
    let ctx = makeOpaqueContext(width: w, height: h)
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    drawBackground(in: ctx, width: CGFloat(w), height: CGFloat(h))
    writePNG(ctx.makeImage()!, to: smallBackImgSet.appendingPathComponent("back-\(scaleName).png"))
}

// Small Front
let smallFrontLayer = smallStackDir.appendingPathComponent("Front.imagestacklayer")
writeJSON(["info": ["version": 1, "author": "xcode"]], to: smallFrontLayer.appendingPathComponent("Contents.json"))
let smallFrontImgSet = smallFrontLayer.appendingPathComponent("Content.imageset")
writeJSON([
    "images": [
        ["filename": "front-400x240.png", "idiom": "tv", "scale": "1x"],
        ["filename": "front-800x480.png", "idiom": "tv", "scale": "2x"]
    ],
    "info": ["version": 1, "author": "xcode"]
], to: smallFrontImgSet.appendingPathComponent("Contents.json"))

for (w, h, scaleName, scale) in [(400, 240, "400x240", CGFloat(0.21)), (800, 480, "800x480", CGFloat(0.42))] {
    let ctx = makeTransparentContext(width: w, height: h)
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    drawForegroundLogo(in: ctx, centerX: CGFloat(w) / 2, centerY: CGFloat(h) / 2, scale: scale)
    writePNG(ctx.makeImage()!, to: smallFrontImgSet.appendingPathComponent("front-\(scaleName).png"))
}

// 4. Top Shelf Image (1920x720 @1x, 3840x1440 @2x)
let topShelfDir = targetDir.appendingPathComponent("Top Shelf Image.imageset")
writeJSON([
    "images": [
        ["filename": "topshelf-1920x720.png", "idiom": "tv", "scale": "1x"],
        ["filename": "topshelf-3840x1440.png", "idiom": "tv", "scale": "2x"]
    ],
    "info": ["version": 1, "author": "xcode"]
], to: topShelfDir.appendingPathComponent("Contents.json"))

for (w, h, scaleName, scale) in [(1920, 720, "1920x720", CGFloat(0.60)), (3840, 1440, "3840x1440", CGFloat(1.20))] {
    let ctx = makeOpaqueContext(width: w, height: h)
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    drawBackground(in: ctx, width: CGFloat(w), height: CGFloat(h))
    drawForegroundLogo(in: ctx, centerX: CGFloat(w) / 2, centerY: CGFloat(h) / 2, scale: scale)
    writePNG(ctx.makeImage()!, to: topShelfDir.appendingPathComponent("topshelf-\(scaleName).png"))
}

// 5. Top Shelf Image Wide (2320x720 @1x, 4640x1440 @2x)
let topShelfWideDir = targetDir.appendingPathComponent("Top Shelf Image Wide.imageset")
writeJSON([
    "images": [
        ["filename": "topshelf-wide-2320x720.png", "idiom": "tv", "scale": "1x"],
        ["filename": "topshelf-wide-4640x1440.png", "idiom": "tv", "scale": "2x"]
    ],
    "info": ["version": 1, "author": "xcode"]
], to: topShelfWideDir.appendingPathComponent("Contents.json"))

for (w, h, scaleName, scale) in [(2320, 720, "2320x720", CGFloat(0.60)), (4640, 1440, "4640x1440", CGFloat(1.20))] {
    let ctx = makeOpaqueContext(width: w, height: h)
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    drawBackground(in: ctx, width: CGFloat(w), height: CGFloat(h))
    drawForegroundLogo(in: ctx, centerX: CGFloat(w) / 2, centerY: CGFloat(h) / 2, scale: scale)
    writePNG(ctx.makeImage()!, to: topShelfWideDir.appendingPathComponent("topshelf-wide-\(scaleName).png"))
}

print("Successfully generated TVAppIcon.brandassets!")
