// Renders Glint's app icon and writes Resources/AppIcon.icns (+ a 1024px PNG preview).
// Usage: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func render(size px: Int) -> CGImage {
    let s = CGFloat(px) / canvas
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // Apple's macOS icon grid: 824pt body centred on a 1024 canvas, continuous-corner squircle.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath

    // drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.15, blue: 0.5, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // background gradient: electric blue (top) to deep violet (bottom)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.33, green: 0.55, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.38, green: 0.30, blue: 0.95, alpha: 1),
        CGColor(srgbRed: 0.20, green: 0.10, blue: 0.48, alpha: 1),
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: body.maxY), end: CGPoint(x: 724, y: body.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // soft light bloom behind the sparkle
    let bloom = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.38),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 330, options: [])

    // glossy top edge
    let gloss = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.maxY - 260), options: [])
    ctx.restoreGState()

    // viewfinder corner brackets
    let inset: CGFloat = 228, arm: CGFloat = 120, r: CGFloat = 46
    let lo = inset, hi = canvas - inset
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.25))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.96))
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (cx, cy, dx, dy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0), (lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        ctx.move(to: CGPoint(x: cx, y: cy + dy * arm))
        ctx.addLine(to: CGPoint(x: cx, y: cy + dy * r))
        ctx.addQuadCurve(to: CGPoint(x: cx + dx * r, y: cy), control: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // the glint: a four-point sparkle plus a small companion
    func sparkle(_ c: CGPoint, _ radius: CGFloat, pinch: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let k = radius * pinch
        p.move(to: CGPoint(x: c.x, y: c.y + radius))
        p.addQuadCurve(to: CGPoint(x: c.x + radius, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - radius), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x - radius, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + radius), control: CGPoint(x: c.x - k, y: c.y + k))
        p.closeSubpath()
        return p
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: CGColor(srgbRed: 1, green: 0.95, blue: 0.8, alpha: 0.9))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(sparkle(CGPoint(x: 500, y: 500), 178, pinch: 0.13))
    ctx.fillPath()
    ctx.addPath(sparkle(CGPoint(x: 640, y: 640), 62, pinch: 0.15))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func png(_ img: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Glint.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    png(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    png(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
png(render(size: 1024), to: resources.appendingPathComponent("AppIcon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
