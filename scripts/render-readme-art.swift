// Renders docs/images/menubar-states-{light,dark}.png from the app's own MenuBarIcon drawing.
// Usage: scripts/render-readme-art.sh
import AppKit

let out = CommandLine.arguments[1]
let scale: CGFloat = 4
let cell: CGFloat = 34, pad: CGFloat = 8
let states = MenuBarIconState.allCases

for (name, fg, bg) in [("light", NSColor.black, NSColor(white: 0.96, alpha: 1)), ("dark", NSColor.white, NSColor(white: 0.16, alpha: 1))] {
    let width = pad * 2 + cell * CGFloat(states.count), height = cell + pad * 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    bg.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: 10, yRadius: 10).fill()
    for (i, state) in states.enumerated() {
        let icon = MenuBarIcon.image(for: state)
        // Tint the template image the way the menu bar does.
        let tinted = NSImage(size: icon.size, flipped: false) { r in
            icon.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true
        }
        let x = pad + CGFloat(i) * cell + (cell - 22) / 2
        tinted.draw(in: NSRect(x: x, y: pad + (cell - 22) / 2, width: 22, height: 22))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/menubar-states-\(name).png"))
}
