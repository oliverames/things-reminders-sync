import AppKit

/// What the menu bar icon shows. Kept free of SwiftUI and SyncCore so the drawing can be rendered on
/// its own for previews (`scripts/render-menubar-icons.sh`).
enum MenuBarIconState: CaseIterable {
    case idle, syncing, paused, error, needsSetup
}

/// The app's menu bar mark: a rounded to-do checkbox with a check (the shape both Things and Reminders
/// use for an item) and a small badge in the corner that says what sync is doing. Drawn as a template
/// image, so macOS tints it for light, dark, and tinted menu bars. Original artwork; nothing is taken
/// from Things' or Reminders' assets.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: MenuBarIconState) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description(for: state)
        return image
    }

    static func description(for state: MenuBarIconState) -> String {
        switch state {
        case .idle: "Things Reminders Sync: up to date"
        case .syncing: "Things Reminders Sync: syncing"
        case .paused: "Things Reminders Sync: paused"
        case .error: "Things Reminders Sync: needs attention"
        case .needsSetup: "Things Reminders Sync: setup needed"
        }
    }

    private static func draw(_ state: MenuBarIconState) {
        NSColor.black.set()

        // Checkbox: a rounded square. Dashed while setup is incomplete.
        let box = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1.25, width: 12.5, height: 12.5), xRadius: 3.4, yRadius: 3.4)
        box.lineWidth = 1.5
        // Ten dashes divide the outline evenly.
        if state == .needsSetup { box.setLineDash([2.42, 2.0], count: 2, phase: 1.2) }
        box.stroke()

        // Check mark (left out while setup is incomplete).
        if state != .needsSetup {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 4.3, y: 7.6))
            check.line(to: NSPoint(x: 6.5, y: 9.9))
            check.line(to: NSPoint(x: 10.6, y: 4.9))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        }

        // Badge in the bottom-right corner, cut out of the box so the two read as separate shapes.
        let center = NSPoint(x: 13.3, y: 13.3)
        let cut = NSBezierPath(ovalIn: NSRect(x: center.x - 5.6, y: center.y - 5.6, width: 11.2, height: 11.2))
        NSGraphicsContext.current?.compositingOperation = .clear
        cut.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        let badgeRect = NSRect(x: center.x - 4.4, y: center.y - 4.4, width: 8.8, height: 8.8)
        switch state {
        case .idle:
            drawSymbol("arrow.triangle.2.circlepath", in: badgeRect, pointSize: 7.6, filled: false)
        case .syncing:
            // A solid disc with the arrows knocked out reads as "active" next to the idle outline.
            NSBezierPath(ovalIn: badgeRect).fill()
            drawSymbol("arrow.triangle.2.circlepath", in: badgeRect.insetBy(dx: 1.4, dy: 1.4), pointSize: 5.6, filled: true)
        case .paused:
            drawSymbol("pause.fill", in: badgeRect, pointSize: 7, filled: false)
        case .error:
            NSBezierPath(ovalIn: badgeRect).fill()
            drawSymbol("exclamationmark", in: badgeRect.insetBy(dx: 1.2, dy: 1.2), pointSize: 6.4, filled: true)
        case .needsSetup:
            drawSymbol("ellipsis", in: badgeRect, pointSize: 7, filled: false)
        }
    }

    /// Draws an SF Symbol centered in `rect`. `filled` knocks it out of whatever is already drawn.
    private static func drawSymbol(_ name: String, in rect: NSRect, pointSize: CGFloat, filled: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let s = symbol.size
        let target = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
        symbol.draw(in: target, from: .zero, operation: filled ? .destinationOut : .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }
}
