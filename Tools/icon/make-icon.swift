// Draws the Telemic app icon and writes App/Resources/AppIcon.icns.
// Run from the repo root: swift Tools/icon/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, ~185/1024 corner radius, soft drop shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 24 / 1024,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.16, green: 0.42, blue: 0.98, alpha: 1).cgColor,
                                   NSColor(red: 0.05, green: 0.75, blue: 0.80, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // Drawn from plain shapes (SF Symbols may not be used in app icons):
    // a microphone, with waves leaving to the right — "this mic, sent elsewhere".
    let u = s / 1024
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)
    let cx = 450 * u
    // Capsule head.
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - 72 * u, y: 450 * u, width: 144 * u, height: 290 * u),
                       cornerWidth: 72 * u, cornerHeight: 72 * u, transform: nil))
    ctx.fillPath()
    // Cradle, stem, base.
    ctx.setLineWidth(42 * u)
    ctx.addArc(center: CGPoint(x: cx, y: 540 * u), radius: 138 * u, startAngle: 0, endAngle: .pi, clockwise: true)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: cx, y: 402 * u)); ctx.addLine(to: CGPoint(x: cx, y: 310 * u)); ctx.strokePath()
    ctx.move(to: CGPoint(x: cx - 95 * u, y: 310 * u)); ctx.addLine(to: CGPoint(x: cx + 95 * u, y: 310 * u)); ctx.strokePath()
    // Waves.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    ctx.setLineWidth(30 * u)
    for (i, r) in [70.0, 135.0, 200.0].enumerated() {
        let a = CGFloat([0.62, 0.55, 0.5][i])
        ctx.addArc(center: CGPoint(x: 590 * u, y: 560 * u), radius: CGFloat(r) * u, startAngle: -a, endAngle: a, clockwise: false)
        ctx.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "build/AppIcon-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "App/Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote App/Resources/AppIcon.icns" : "iconutil failed")
