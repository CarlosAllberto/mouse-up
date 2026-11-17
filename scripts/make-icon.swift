// Draws the Mouse Up app icon and writes an AppIcon.appiconset. Usage: swift icon.swift <out.appiconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Rounded square with the standard macOS margin (824pt plate in a 1024 canvas).
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(platePath); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(platePath); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1),
        CGColor(red: 0.36, green: 0.25, blue: 0.90, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let white = CGColor(gray: 1, alpha: 1)
    // Mouse body.
    let body = CGRect(x: 362, y: 190, width: 300, height: 450)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 150, cornerHeight: 150, transform: nil))
    ctx.setFillColor(white); ctx.fillPath()
    // Button split and wheel, cut out in the gradient's mid color.
    let ink = CGColor(red: 0.28, green: 0.40, blue: 0.95, alpha: 1)
    ctx.setStrokeColor(ink); ctx.setLineWidth(14); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 512, y: 640)); ctx.addLine(to: CGPoint(x: 512, y: 470)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 362, y: 470)); ctx.addLine(to: CGPoint(x: 662, y: 470)); ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 490, y: 520, width: 44, height: 80), cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(ink); ctx.fillPath()
    // Up chevron above the mouse.
    ctx.setStrokeColor(white); ctx.setLineWidth(44); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 420, y: 720)); ctx.addLine(to: CGPoint(x: 512, y: 812)); ctx.addLine(to: CGPoint(x: 604, y: 720))
    ctx.strokePath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try render(pt * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
