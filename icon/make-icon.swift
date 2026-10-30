// Draws the Jog Scroll app icon as icon/AppIcon.png plus an .iconset of every size.
// Run from the repo root:
//   swift icon/make-icon.swift && iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns
//
// A DJ jog wheel on a dark rounded square: brushed-metal rim, grooved platter,
// a teal position marker, a rotation arc, and scroll chevrons on the centre cap.

import AppKit

let size: CGFloat = 1024
let teal = CGColor(red: 0.25, green: 0.88, blue: 0.77, alpha: 1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
}

func draw(_ ctx: CGContext) {
    let center = CGPoint(x: size / 2, y: size / 2)

    // Background: macOS icon grid (824 pt body, ~185 pt corners), dark blue-charcoal gradient.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0.10, 0.11, 0.16))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.20, 0.22, 0.32), rgb(0.07, 0.08, 0.12)]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // Soft teal glow behind the wheel.
    ctx.drawRadialGradient(gradient([rgb(0.25, 0.88, 0.77, 0.22), rgb(0.25, 0.88, 0.77, 0)]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: 420, options: [])
    ctx.restoreGState()

    // Rim: brushed metal ring with a drop shadow.
    let rimR: CGFloat = 318
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0, 0, 0, 0.6))
    ctx.setFillColor(rgb(0.5, 0.52, 0.56))
    ctx.fillEllipse(in: circle(center, rimR))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, rimR))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.92, 0.93, 0.95), rgb(0.55, 0.57, 0.62), rgb(0.30, 0.32, 0.36)], [0, 0.55, 1]),
                           start: CGPoint(x: center.x - rimR, y: center.y + rimR),
                           end: CGPoint(x: center.x + rimR, y: center.y - rimR), options: [])
    ctx.restoreGState()

    // Grip dimples around the rim.
    let dimples = 48
    for i in 0..<dimples {
        let a = CGFloat(i) / CGFloat(dimples) * 2 * .pi
        let p = CGPoint(x: center.x + cos(a) * (rimR - 17), y: center.y + sin(a) * (rimR - 17))
        ctx.setFillColor(rgb(0.15, 0.16, 0.19, 0.55))
        ctx.fillEllipse(in: circle(p, 6.5))
    }

    // Platter: dark disc with concentric grooves and a light sheen.
    let platterR: CGFloat = 282
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, platterR))
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0.17, 0.18, 0.23), rgb(0.06, 0.065, 0.09)]),
                           startCenter: CGPoint(x: center.x - 60, y: center.y + 80), startRadius: 0,
                           endCenter: center, endRadius: platterR, options: [.drawsAfterEndLocation])
    ctx.setLineWidth(2)
    var r: CGFloat = 112
    while r < platterR - 8 {
        ctx.setStrokeColor(rgb(1, 1, 1, r.truncatingRemainder(dividingBy: 28) < 14 ? 0.07 : 0.035))
        ctx.strokeEllipse(in: circle(center, r))
        r += 14
    }
    // Diagonal sheen across the platter.
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)], [0.3, 0.5, 0.7]),
                           start: CGPoint(x: center.x - platterR, y: center.y - platterR),
                           end: CGPoint(x: center.x + platterR, y: center.y + platterR), options: [])
    ctx.restoreGState()

    // Rotation arc: a teal sweep just inside the platter edge, ending in an arrowhead.
    let arcR: CGFloat = 246
    let start: CGFloat = 205 * .pi / 180, end: CGFloat = 115 * .pi / 180   // clockwise from lower left to top
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: rgb(0.25, 0.88, 0.77, 0.8))
    ctx.setStrokeColor(teal)
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: arcR, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
    // Arrowhead pointing along the clockwise direction at the arc's end.
    let tip = CGPoint(x: center.x + cos(end) * arcR, y: center.y + sin(end) * arcR)
    let tangent = CGPoint(x: sin(end), y: -cos(end))      // clockwise direction
    let normal = CGPoint(x: cos(end), y: sin(end))
    let head: CGFloat = 42
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: tip.x + tangent.x * head, y: tip.y + tangent.y * head))
    arrow.addLine(to: CGPoint(x: tip.x + normal.x * head * 0.8, y: tip.y + normal.y * head * 0.8))
    arrow.addLine(to: CGPoint(x: tip.x - normal.x * head * 0.8, y: tip.y - normal.y * head * 0.8))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.setFillColor(teal)
    ctx.fillPath()
    ctx.restoreGState()

    // Centre cap: metal dome with up/down scroll chevrons.
    let capR: CGFloat = 96
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0, 0, 0.6))
    ctx.setFillColor(rgb(0.6, 0.62, 0.66))
    ctx.fillEllipse(in: circle(center, capR))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, capR))
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0.96, 0.97, 0.98), rgb(0.62, 0.64, 0.69), rgb(0.38, 0.40, 0.45)], [0, 0.6, 1]),
                           startCenter: CGPoint(x: center.x - 30, y: center.y + 40), startRadius: 0,
                           endCenter: center, endRadius: capR, options: [])
    ctx.restoreGState()

    ctx.setStrokeColor(rgb(0.13, 0.14, 0.18))
    ctx.setLineWidth(15)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for dir: CGFloat in [1, -1] {
        let y = center.y + dir * 22
        ctx.move(to: CGPoint(x: center.x - 34, y: y))
        ctx.addLine(to: CGPoint(x: center.x, y: y + dir * 30))
        ctx.addLine(to: CGPoint(x: center.x + 34, y: y))
        ctx.strokePath()
    }
}

// Render once at 1024 px, then scale down for each size the .icns needs.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
draw(ctx)
let master = NSImage(size: NSSize(width: size, height: size))
master.addRepresentation(rep)

let iconset = URL(fileURLWithPath: "icon/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon/AppIcon.png"))

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
print("Wrote icon/AppIcon.png and icon/AppIcon.iconset")
