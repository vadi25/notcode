#!/usr/bin/env swift
// Generates NotCode's app icon (AppIcon.icns) and the DMG window background.
// Run from the repo root: swift scripts/generate-artwork.swift
// Outputs are committed so normal builds need no artwork step.

import AppKit

let brandDeep = NSColor(srgbRed: 0.016, green: 0.373, blue: 0.275, alpha: 1)   // #065f46
let brand = NSColor(srgbRed: 0.016, green: 0.471, blue: 0.341, alpha: 1)       // #047857
let brandLight = NSColor(srgbRed: 0.020, green: 0.588, blue: 0.412, alpha: 1)  // #059669
let paper = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.957, alpha: 1)
let ink = NSColor(srgbRed: 0.063, green: 0.063, blue: 0.070, alpha: 1)

func bitmap(widthPx: Int, heightPx: Int, pointsWide: CGFloat, pointsHigh: CGFloat,
            draw: (CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: widthPx, pixelsHigh: heightPx,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pointsWide, height: pointsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: pointsWide, height: pointsHigh))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func bellImage(pointSize: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let symbol = NSImage(systemSymbolName: "bell.badge.fill",
                         accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    // Render as a white template.
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    return tinted
}

// MARK: - App icon (1024pt master, Apple-style rounded square at ~80% canvas)

func drawIcon(canvas: CGRect) {
    let side = canvas.width
    let plate = canvas.insetBy(dx: side * 0.10, dy: side * 0.10)
    let radius = plate.width * 0.2237

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.008)
    shadow.shadowBlurRadius = side * 0.02
    shadow.set()

    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSGradient(colors: [brandLight, brand, brandDeep])!
        .draw(in: path, angle: -90)
    NSShadow().set()

    // Subtle top sheen.
    let sheen = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18),
                        NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: sheen, angle: -90)

    let bell = bellImage(pointSize: side * 0.42)
    let bellSize = bell.size
    let origin = CGPoint(x: canvas.midX - bellSize.width / 2,
                         y: canvas.midY - bellSize.height / 2)
    let bellShadow = NSShadow()
    bellShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    bellShadow.shadowOffset = NSSize(width: 0, height: -side * 0.006)
    bellShadow.shadowBlurRadius = side * 0.012
    bellShadow.set()
    bell.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}

// MARK: - DMG background (660x400pt window, retina pixels)

func drawDMGBackground(canvas: CGRect) {
    paper.set()
    canvas.fill()

    // Faint brand wash at the top.
    NSGradient(colors: [brand.withAlphaComponent(0.06),
                        brand.withAlphaComponent(0.0)])!
        .draw(in: canvas, angle: -90)

    // Wordmark: bell chip + "NotCode".
    let chipSide: CGFloat = 34
    let chip = CGRect(x: canvas.midX - 76, y: canvas.height - 84,
                      width: chipSide, height: chipSide)
    ink.set()
    NSBezierPath(roundedRect: chip, xRadius: 9, yRadius: 9).fill()
    let bell = bellImage(pointSize: 17)
    bell.draw(at: CGPoint(x: chip.midX - bell.size.width / 2,
                          y: chip.midY - bell.size.height / 2),
              from: .zero, operation: .sourceOver, fraction: 1)
    let title = NSAttributedString(string: "NotCode", attributes: [
        .font: NSFont.systemFont(ofSize: 28, weight: .bold),
        .foregroundColor: ink,
    ])
    title.draw(at: CGPoint(x: chip.maxX + 12,
                           y: chip.midY - title.size().height / 2))

    let subtitle = NSAttributedString(
        string: "Drag NotCode to Applications to install",
        attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.55),
        ])
    subtitle.draw(at: CGPoint(x: canvas.midX - subtitle.size().width / 2,
                              y: canvas.height - 116))

    // Arrow between the two icon slots (icons sit at x=165 and x=495,
    // centered around y≈195 in the 660x400 window).
    let y: CGFloat = canvas.height - 215
    let start = CGPoint(x: 245, y: y)
    let end = CGPoint(x: 405, y: y)
    let arrow = NSBezierPath()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.move(to: start)
    arrow.line(to: end)
    arrow.move(to: CGPoint(x: end.x - 22, y: y + 16))
    arrow.line(to: end)
    arrow.line(to: CGPoint(x: end.x - 22, y: y - 16))
    brand.withAlphaComponent(0.75).set()
    arrow.stroke()
}

// MARK: - Emit files

let fm = FileManager.default
try? fm.createDirectory(atPath: "NotCode/Resources", withIntermediateDirectories: true)
try? fm.createDirectory(atPath: "assets/dmg", withIntermediateDirectories: true)

// Iconset: render the 1024 master once per required size (crisper than scaling).
let iconset = "assets/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let rep = bitmap(widthPx: px, heightPx: px,
                     pointsWide: CGFloat(px), pointsHigh: CGFloat(px), draw: drawIcon)
    let suffix = scale == 2 ? "@2x" : ""
    writePNG(rep, to: "\(iconset)/icon_\(points)x\(points)\(suffix).png")
}

// DMG background at 2x with correct point size so Finder renders it sharp.
let bg = bitmap(widthPx: 1320, heightPx: 800, pointsWide: 660, pointsHigh: 400,
                draw: drawDMGBackground)
writePNG(bg, to: "assets/dmg/background.png")
// A plain preview at 1x for quick eyeballing.
writePNG(bitmap(widthPx: 660, heightPx: 400, pointsWide: 660, pointsHigh: 400,
                draw: drawDMGBackground), to: "assets/dmg/background-preview.png")
writePNG(bitmap(widthPx: 512, heightPx: 512, pointsWide: 512, pointsHigh: 512,
                draw: drawIcon), to: "assets/dmg/icon-preview.png")
print("done — run: iconutil -c icns assets/AppIcon.iconset -o NotCode/Resources/AppIcon.icns")
