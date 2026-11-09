// Renders an iconset (one master PNG per size) with an SF Symbol on a rounded square.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size, flipped: false) { rect in
        let inset = rect.insetBy(dx: CGFloat(px) * 0.08, dy: CGFloat(px) * 0.08)
        let path = NSBezierPath(roundedRect: inset, xRadius: CGFloat(px) * 0.2, yRadius: CGFloat(px) * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.98, alpha: 1),
                   ending: NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.82, alpha: 1))!.draw(in: path, angle: -90)
        // The menu bar mark (Sources/ThingsRemindersSync/MenuBarIcon.swift), in white: a rounded to-do
        // checkbox with a check and a sync badge. Coordinates are the mark's 18-point grid, scaled.
        let k = CGFloat(px) * 0.56 / 18
        let ox = (rect.width - 18 * k) / 2, oy = (rect.height - 18 * k) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * k, y: oy + (18 - y) * k) }
        NSColor.white.set()
        let box = NSBezierPath(roundedRect: NSRect(x: ox + 1.25 * k, y: oy + (18 - 13.75) * k, width: 12.5 * k, height: 12.5 * k),
                               xRadius: 3.4 * k, yRadius: 3.4 * k)
        box.lineWidth = 1.5 * k
        box.stroke()
        let check = NSBezierPath()
        check.move(to: pt(4.3, 7.6)); check.line(to: pt(6.5, 9.9)); check.line(to: pt(10.6, 4.9))
        check.lineWidth = 1.6 * k; check.lineCapStyle = .round; check.lineJoinStyle = .round
        check.stroke()
        // Cut the badge area out of the box in the tile's colour, then draw the sync arrows.
        let c = pt(13.3, 13.3)
        let cut = NSBezierPath(ovalIn: NSRect(x: c.x - 5.6 * k, y: c.y - 5.6 * k, width: 11.2 * k, height: 11.2 * k))
        NSGraphicsContext.saveGraphicsState()
        cut.addClip()
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.98, alpha: 1),
                   ending: NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.82, alpha: 1))!.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        let config = NSImage.SymbolConfiguration(pointSize: 7.6 * k, weight: .bold).applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
