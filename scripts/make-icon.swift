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
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.5, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
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
