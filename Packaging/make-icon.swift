#!/usr/bin/env swift
// Renders the EasyScan app icon as a 1024x1024 PNG, using AppKit + CoreGraphics only.
//
//   swift Packaging/make-icon.swift <out.png>
//
// Layout follows Apple's macOS icon grid: an 824x824 body centred on a 1024 canvas (100 px margin for the
// drop shadow), with continuous ("squircle") corners approximated by a superellipse.
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.png>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[1])

let canvas: CGFloat = 1024
let pixels = Int(canvas)

// MARK: - Helpers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: stops.map(\.0) as CFArray,
               locations: stops.map(\.1))!
}

/// Superellipse |x/a|^n + |y/b|^n = 1. With n = 5 its 45-degree extent matches a rounded rect whose corner radius
/// is ~22% of the side, but with continuous curvature like Apple's icon shape.
func squircle(in rect: CGRect, exponent n: CGFloat = 5, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0..<samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// A sheet of paper with a folded top-right corner. Coordinates are top-left origin (the context is flipped).
func documentPath(_ r: CGRect, fold: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radius)
    p.closeSubpath()
    return p
}

func foldPath(_ r: CGRect, fold: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let corner = CGPoint(x: r.maxX - fold, y: r.minY + fold)
    p.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
    p.addArc(tangent1End: corner, tangent2End: CGPoint(x: r.maxX, y: r.minY + fold), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
    p.closeSubpath()
    return p
}

func capsule(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
}

// MARK: - Context

guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("error: could not create bitmap context\n".utf8))
    exit(1)
}
// Work in top-left-origin coordinates. Note: CG shadow offsets ignore the CTM, so a negative y still means "down".
ctx.translateBy(x: 0, y: canvas)
ctx.scaleBy(x: 1, y: -1)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let body = squircle(in: bodyRect)
let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

// MARK: - Body

// Drop shadow under the whole tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.30))
ctx.addPath(body)
ctx.setFillColor(color(0x1C6FBF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(body)
ctx.clip()

// Two-tone gradient: deep teal at the top-left to blue at the bottom-right.
ctx.drawLinearGradient(gradient([(color(0x11B5A4), 0), (color(0x1690B8), 0.48), (color(0x2A4FD4), 1)]),
                       start: CGPoint(x: 260, y: 100), end: CGPoint(x: 764, y: 924), options: extend)

// Soft top highlight and a gentle darkening towards the bottom edge.
ctx.drawRadialGradient(gradient([(color(0xFFFFFF, 0.24), 0), (color(0xFFFFFF, 0), 1)]),
                       startCenter: CGPoint(x: 512, y: 60), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 60), endRadius: 620, options: [])
ctx.drawLinearGradient(gradient([(color(0x0B1E5B, 0), 0), (color(0x0B1E5B, 0.22), 1)]),
                       start: CGPoint(x: 512, y: 600), end: CGPoint(x: 512, y: 924), options: extend)
ctx.restoreGState()

// Thin inner rim light (stroke centred on the edge, clipped so only the inner half shows).
ctx.saveGState()
ctx.addPath(body)
ctx.clip()
ctx.addPath(body)
ctx.setLineWidth(5)
ctx.setStrokeColor(color(0xFFFFFF, 0.22))
ctx.strokePath()
ctx.restoreGState()

// MARK: - Glyph: document with a scan beam

let doc = CGRect(x: 302, y: 222, width: 420, height: 572)
let fold: CGFloat = 118
let docPath = documentPath(doc, fold: fold, radius: 30)
let scanY: CGFloat = 520  // centre line of the scan beam

// Paper with a soft, blue-tinted shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: color(0x081A52, 0.40))
ctx.addPath(docPath)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(docPath)
ctx.clip()
ctx.drawLinearGradient(gradient([(color(0xFFFFFF), 0), (color(0xE9F0FB), 1)]),
                       start: CGPoint(x: 0, y: doc.minY), end: CGPoint(x: 0, y: doc.maxY), options: extend)

// Text lines: the part above the beam is "already scanned" (tinted), the part below is plain grey.
let left = doc.minX + 58
let right = doc.maxX - 58
let lineHeight: CGFloat = 22
let lines: [(y: CGFloat, end: CGFloat)] = [
    (300, doc.maxX - fold - 28),   // title line, stops short of the fold
    (362, right - 40),
    (414, right),
    (466, right - 70),
    (574, right),
    (626, right - 24),
    (678, right),
    (730, right - 120),
]
for line in lines {
    let isTitle = line.y == 300
    let h = isTitle ? lineHeight + 10 : lineHeight
    let rect = CGRect(x: left, y: line.y - h / 2, width: line.end - left, height: h)
    let scanned = line.y < scanY
    ctx.addPath(capsule(rect))
    ctx.setFillColor(scanned ? color(isTitle ? 0x2563D9 : 0x4F86E6, isTitle ? 0.95 : 0.80) : color(0xC3CEE0))
    ctx.fillPath()
}

// Light wash trailing the beam over the scanned area.
ctx.drawLinearGradient(gradient([(color(0x3FE3F5, 0), 0), (color(0x3FE3F5, 0.30), 1)]),
                       start: CGPoint(x: 0, y: scanY - 170), end: CGPoint(x: 0, y: scanY), options: [])
ctx.restoreGState()

// Folded corner.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -4, height: -4), blur: 12, color: color(0x081A52, 0.25))
ctx.addPath(foldPath(doc, fold: fold, radius: 18))
ctx.clip()
ctx.drawLinearGradient(gradient([(color(0xD6E2F5), 0), (color(0xB4C6E6), 1)]),
                       start: CGPoint(x: doc.maxX - fold, y: doc.minY + fold),
                       end: CGPoint(x: doc.maxX - fold / 2, y: doc.minY + fold / 2), options: extend)
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -6, height: -8), blur: 14, color: color(0x081A52, 0.28))
ctx.addPath(foldPath(doc, fold: fold, radius: 18))
ctx.setFillColor(color(0xD0DDF2))
ctx.fillPath()
ctx.restoreGState()

// Scan beam: extends past the paper like a scanner's light bar, with a cyan glow.
let beam = CGRect(x: doc.minX - 52, y: scanY - 11, width: doc.width + 104, height: 22)
for (blur, alpha) in [(CGFloat(60), CGFloat(0.9)), (26, 1.0)] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: color(0x48F0FF, alpha))
    ctx.addPath(capsule(beam))
    ctx.setFillColor(color(0x5CF0FF))
    ctx.fillPath()
    ctx.restoreGState()
}
ctx.addPath(capsule(beam.insetBy(dx: 10, dy: 6)))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()

// MARK: - Write PNG

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("error: could not render image\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: canvas, height: canvas)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: could not encode PNG\n".utf8))
    exit(1)
}
do {
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: outputURL)
    print("wrote \(outputURL.path) (\(pixels)x\(pixels))")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
