// Zeichnet das App-Icon (Tunnelportal mit Licht am Ende) als .iconset.
// Aufruf: swift icon.swift <ziel.iconset>

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let t = NSAffineTransform(); t.scale(by: s); t.concat()

    // Grundform nach macOS-Icon-Raster: 824er Fläche mit 100er Rand.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.17, green: 0.33, blue: 0.40, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.10, blue: 0.16, alpha: 1))!.draw(in: body, angle: -90)

    // Drei Bögen, nach innen dunkler: der Tunnel.
    let cx: CGFloat = 512, base: CGFloat = 250
    for (r, a) in [(270.0, 0.95), (195.0, 0.55), (120.0, 0.28)] as [(CGFloat, CGFloat)] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx - r, y: base))
        p.line(to: NSPoint(x: cx - r, y: base + 200))
        p.appendArc(withCenter: NSPoint(x: cx, y: base + 200), radius: r, startAngle: 180, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: cx + r, y: base))
        p.lineWidth = 42
        p.lineCapStyle = .round
        NSColor.white.withAlphaComponent(a).setStroke()
        p.stroke()
    }

    // Licht am Ende: grüner Punkt mit Schein.
    let glow = NSGradient(colors: [NSColor(red: 0.3, green: 1, blue: 0.55, alpha: 0.7), .clear])!
    glow.draw(fromCenter: NSPoint(x: cx, y: base + 150), radius: 0,
              toCenter: NSPoint(x: cx, y: base + 150), radius: 110, options: [])
    NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 36, y: base + 114, width: 72, height: 72)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
