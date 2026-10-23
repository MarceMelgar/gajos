// Genera el ícono de la app: una rueda de gajos naranjas sobre fondo oscuro.
// Uso: swift scripts/make-icon.swift <carpeta.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func drawIcon(side: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = side / 1024

    let bg = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedWhite: 0.20, alpha: 1),
               ending: NSColor(calibratedWhite: 0.08, alpha: 1))!.draw(in: bgPath, angle: -90)

    let center = NSPoint(x: 512 * s, y: 512 * s)
    let outer = 300 * s, inner = 110 * s, count = 6
    let step = 360.0 / Double(count)
    for i in 0..<count {
        let mid = 90 - Double(i) * step
        let half = step / 2 - 4
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer, startAngle: mid + half, endAngle: mid - half, clockwise: true)
        path.appendArc(withCenter: center, radius: inner, startAngle: mid - half + 6, endAngle: mid + half - 6, clockwise: false)
        path.close()
        let t = CGFloat(i) / CGFloat(count)
        let color = NSColor(calibratedRed: 1, green: 0.48 + 0.25 * t, blue: 0.12 + 0.1 * t, alpha: 1)
        NSGradient(starting: color.blended(withFraction: 0.25, of: .white)!, ending: color)!
            .draw(in: path, relativeCenterPosition: .zero)
    }
    NSColor(calibratedRed: 1, green: 0.62, blue: 0.2, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 60 * s, y: center.y - 60 * s, width: 120 * s, height: 120 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let rep = drawIcon(side: CGFloat(size * scale))
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
