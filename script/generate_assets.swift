#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: generate_assets.swift <output_dir>\n", stderr)
    exit(2)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func renderPNG(size: CGSize, draw: (CGContext, CGRect) -> Void) -> Data {
    let w = Int(size.width)
    let h = Int(size.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to match typical UI coordinates (origin top-left).
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)

    draw(ctx, CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

func drawBackground(ctx: CGContext, rect: CGRect, cornerRadius: CGFloat) {
    let path = CGPath(roundedRect: rect.insetBy(dx: 16, dy: 16), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.12, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.22, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.10, alpha: 1).cgColor,
    ] as CFArray

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])

    // Soft vignette for depth.
    ctx.saveGState()
    let vignetteColors = [
        NSColor.black.withAlphaComponent(0.00).cgColor,
        NSColor.black.withAlphaComponent(0.55).cgColor,
    ] as CFArray
    let vignette = CGGradient(colorsSpace: space, colors: vignetteColors, locations: [0, 1])!
    ctx.drawRadialGradient(
        vignette,
        startCenter: CGPoint(x: rect.midX, y: rect.midY),
        startRadius: rect.width * 0.10,
        endCenter: CGPoint(x: rect.midX, y: rect.midY),
        endRadius: rect.width * 0.72,
        options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

func drawEQCurve(ctx: CGContext, rect: CGRect, lineWidth: CGFloat) {
    let inset = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.18)

    let p0 = CGPoint(x: inset.minX, y: inset.midY + inset.height * 0.12)
    let p1 = CGPoint(x: inset.minX + inset.width * 0.22, y: inset.midY - inset.height * 0.08)
    let p2 = CGPoint(x: inset.minX + inset.width * 0.45, y: inset.midY + inset.height * 0.18)
    let p3 = CGPoint(x: inset.minX + inset.width * 0.70, y: inset.midY - inset.height * 0.20)
    let p4 = CGPoint(x: inset.maxX, y: inset.midY + inset.height * 0.05)

    let path = CGMutablePath()
    path.move(to: p0)
    path.addCurve(to: p2, control1: CGPoint(x: p0.x + inset.width * 0.12, y: p0.y), control2: CGPoint(x: p1.x, y: p1.y))
    path.addCurve(to: p4, control1: CGPoint(x: p2.x + inset.width * 0.18, y: p2.y), control2: CGPoint(x: p3.x, y: p3.y))

    // glow
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.25).cgColor)
    ctx.setLineWidth(lineWidth * 2.2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // main
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.95).cgColor)
    ctx.setLineWidth(lineWidth)
    ctx.strokePath()

    // dots
    for p in [p1, p2, p3] {
        let r = lineWidth * 0.9
        let dot = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: dot)
    }
}

func drawIcon(ctx: CGContext, rect: CGRect) {
    drawBackground(ctx: ctx, rect: rect, cornerRadius: 220)

    // MARK: - Signature mark: "Q" ring + EQ curve (stays crisp at small sizes)

    let center = CGPoint(x: rect.midX, y: rect.midY * 0.98)
    let outerR = rect.width * 0.32
    let innerR = rect.width * 0.22

    // EQ curve inside the ring
    ctx.saveGState()
    let innerCircle = CGPath(ellipseIn: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2), transform: nil)
    ctx.addPath(innerCircle)
    ctx.clip()
    let curveRect = CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2)
    drawEQCurve(ctx: ctx, rect: curveRect, lineWidth: rect.width * 0.018)
    ctx.restoreGState()

    // Ring stroke (outer - inner via even-odd fill)
    let space = CGColorSpaceCreateDeviceRGB()
    let ringPath = CGMutablePath()
    ringPath.addEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))
    ringPath.addEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))

    // Tail for "Q"
    let tailW = rect.width * 0.070
    let tailL = rect.width * 0.170
    let tailRect = CGRect(x: center.x + outerR * 0.55, y: center.y - outerR * 0.65, width: tailL, height: tailW)
    let tailPath = CGPath(roundedRect: tailRect, cornerWidth: tailW / 2, cornerHeight: tailW / 2, transform: nil)
    var t = CGAffineTransform.identity
    t = t.translatedBy(x: tailRect.midX, y: tailRect.midY)
    t = t.rotated(by: CGFloat.pi / 4)
    t = t.translatedBy(x: -tailRect.midX, y: -tailRect.midY)
    ringPath.addPath(tailPath, transform: t)

    ctx.saveGState()
    ctx.addPath(ringPath)
    // ring glow
    ctx.setShadow(offset: .zero, blur: rect.width * 0.030, color: NSColor.systemCyan.withAlphaComponent(0.30).cgColor)
    ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.20).cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // ring stroke gradient
    ctx.saveGState()
    ctx.addPath(ringPath)
    ctx.clip(using: .evenOdd)
    let ringGrad = CGGradient(colorsSpace: space, colors: [
        NSColor(calibratedRed: 0.36, green: 0.94, blue: 1.0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.42, green: 0.60, blue: 1.0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.30, green: 0.25, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(ringGrad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // Glass highlight
    ctx.saveGState()
    let highlightRect = CGRect(x: rect.minX + 32, y: rect.minY + 32, width: rect.width - 64, height: rect.height * 0.46)
    let highlight = CGPath(roundedRect: highlightRect, cornerWidth: 200, cornerHeight: 200, transform: nil)
    ctx.addPath(highlight)
    ctx.clip()
    let hlGrad = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0.00).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        hlGrad,
        start: CGPoint(x: highlightRect.minX, y: highlightRect.minY),
        end: CGPoint(x: highlightRect.minX, y: highlightRect.maxY),
        options: []
    )
    ctx.restoreGState()
}

func drawLogo(ctx: CGContext, rect: CGRect) {
    drawBackground(ctx: ctx, rect: rect, cornerRadius: 120)

    let space = CGColorSpaceCreateDeviceRGB()

    // Left mark (same "Q" concept as the app icon)
    let center = CGPoint(x: rect.minX + rect.height * 0.55, y: rect.midY)
    let outerR = rect.height * 0.29
    let innerR = rect.height * 0.19

    ctx.saveGState()
    let innerCircle = CGPath(ellipseIn: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2), transform: nil)
    ctx.addPath(innerCircle)
    ctx.clip()
    let curveRect = CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2)
    drawEQCurve(ctx: ctx, rect: curveRect, lineWidth: rect.height * 0.020)
    ctx.restoreGState()

    let ringPath = CGMutablePath()
    ringPath.addEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))
    ringPath.addEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))

    let tailW = rect.height * 0.065
    let tailL = rect.height * 0.16
    let tailRect = CGRect(x: center.x + outerR * 0.55, y: center.y - outerR * 0.65, width: tailL, height: tailW)
    let tailPath = CGPath(roundedRect: tailRect, cornerWidth: tailW / 2, cornerHeight: tailW / 2, transform: nil)
    var t = CGAffineTransform.identity
    t = t.translatedBy(x: tailRect.midX, y: tailRect.midY)
    t = t.rotated(by: CGFloat.pi / 4)
    t = t.translatedBy(x: -tailRect.midX, y: -tailRect.midY)
    ringPath.addPath(tailPath, transform: t)

    ctx.saveGState()
    ctx.addPath(ringPath)
    ctx.setShadow(offset: .zero, blur: rect.height * 0.03, color: NSColor.systemCyan.withAlphaComponent(0.25).cgColor)
    ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.18).cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(ringPath)
    ctx.clip(using: .evenOdd)
    let ringGrad = CGGradient(colorsSpace: space, colors: [
        NSColor(calibratedRed: 0.36, green: 0.94, blue: 1.0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.42, green: 0.60, blue: 1.0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.30, green: 0.25, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(ringGrad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // Wordmark
    let word = "MACQ"
    let font = NSFont.systemFont(ofSize: rect.height * 0.30, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        .kern: 1.0,
    ]
    let str = NSAttributedString(string: word, attributes: attrs)
    let size = str.size()

    let x = center.x + outerR + rect.height * 0.14
    let y = rect.midY - size.height / 2

    ctx.saveGState()
    ctx.translateBy(x: 0, y: rect.height)
    ctx.scaleBy(x: 1, y: -1)
    str.draw(at: CGPoint(x: x, y: rect.height - y - size.height))
    ctx.restoreGState()
}

func drawMenuBarTemplate(ctx: CGContext, rect: CGRect, muted: Bool) {
    ctx.clear(rect)

    let center = CGPoint(x: rect.midX, y: rect.midY * 0.98)
    let outerR = rect.width * 0.42
    let innerR = rect.width * 0.28

    // Inside curve
    ctx.saveGState()
    let innerCircle = CGPath(ellipseIn: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2), transform: nil)
    ctx.addPath(innerCircle)
    ctx.clip()
    let curveRect = CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2)
    drawEQCurve(ctx: ctx, rect: curveRect, lineWidth: rect.width * 0.055)
    ctx.restoreGState()

    // Ring + Q tail (solid white; treated as a template mask)
    let ringPath = CGMutablePath()
    ringPath.addEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))
    ringPath.addEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))

    let tailW = rect.width * 0.11
    let tailL = rect.width * 0.26
    let tailRect = CGRect(x: center.x + outerR * 0.40, y: center.y - outerR * 0.62, width: tailL, height: tailW)
    let tailPath = CGPath(roundedRect: tailRect, cornerWidth: tailW / 2, cornerHeight: tailW / 2, transform: nil)
    var t = CGAffineTransform.identity
    t = t.translatedBy(x: tailRect.midX, y: tailRect.midY)
    t = t.rotated(by: CGFloat.pi / 4)
    t = t.translatedBy(x: -tailRect.midX, y: -tailRect.midY)
    ringPath.addPath(tailPath, transform: t)

    ctx.saveGState()
    ctx.addPath(ringPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    if muted {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(rect.width * 0.09)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: rect.width * 0.18, y: rect.height * 0.22))
        ctx.addLine(to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.78))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

let iconData = renderPNG(size: CGSize(width: 1024, height: 1024), draw: drawIcon)
try iconData.write(to: outDir.appendingPathComponent("MACQ_icon_1024.png"), options: [.atomic])

let logoData = renderPNG(size: CGSize(width: 1400, height: 700), draw: drawLogo)
try logoData.write(to: outDir.appendingPathComponent("MACQ_logo.png"), options: [.atomic])

let menubarData = renderPNG(size: CGSize(width: 36, height: 36)) { ctx, rect in
    drawMenuBarTemplate(ctx: ctx, rect: rect, muted: false)
}
try menubarData.write(to: outDir.appendingPathComponent("MACQMenubarTemplate.png"), options: [.atomic])

let menubarMutedData = renderPNG(size: CGSize(width: 36, height: 36)) { ctx, rect in
    drawMenuBarTemplate(ctx: ctx, rect: rect, muted: true)
}
try menubarMutedData.write(to: outDir.appendingPathComponent("MACQMenubarMutedTemplate.png"), options: [.atomic])

print("Wrote assets to \(outDir.path)")
