import AppKit

/// How the menu bar battery is tinted: Apple's own icon turns yellow in Low Power Mode and red when nearly empty.
enum BatteryTint {
    case normal, lowPower, low

    var color: NSColor? {
        switch self {
        case .normal: nil
        case .lowPower: NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
        case .low: NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
        }
    }
}

/// Draws the menu bar battery the way macOS does: a rounded body with the percentage inside it,
/// the charged part solid and the rest dimmed. The digits are knocked out of the shape, so they stay
/// legible on any menu bar. Untinted icons are template images (macOS recolors them for light and dark
/// menu bars); tinted ones carry their own color.
enum MenuBarBattery {
    static func image(level: Double, charging: Bool, showPercent: Bool, tint: BatteryTint) -> NSImage {
        let body = CGSize(width: 27, height: 13)
        let nub: CGFloat = 2, bolt: CGFloat = charging ? 8 : 0
        let size = NSSize(width: bolt + body.width + nub + 1, height: 16)
        let color = tint.color ?? .black
        let level = min(100, max(0, level))

        let image = NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(x: bolt, y: (size.height - body.height) / 2, width: body.width, height: body.height)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 3.8, yRadius: 3.8)

            color.withAlphaComponent(0.3).setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            color.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width * level / 100, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()

            color.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.maxX + 1, y: rect.midY - 2.5, width: nub, height: 5),
                         xRadius: 1, yRadius: 1).fill()

            if charging, let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) {
                // SF Symbols draw black; tint a copy so the bolt follows the icon's color.
                let glyph = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r)
                    color.setFill()
                    r.fill(using: .sourceIn)
                    return true
                }
                glyph.draw(in: NSRect(x: 0, y: (size.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            }

            if showPercent {
                let text = "\(Int(level))"
                let font = NSFont.systemFont(ofSize: text.count > 2 ? 8.5 : 10.5, weight: .bold)
                func string(_ c: NSColor) -> NSAttributedString {
                    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c])
                }
                let s = string(color).size()
                let origin = NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2)
                let edge = rect.minX + rect.width * level / 100
                // Over the charged part the digits are cut out of a template icon (or drawn dark/white on a
                // tinted one); over the dimmed part they are solid.
                let onFill: NSColor = tint == .lowPower ? NSColor(white: 0.1, alpha: 1) : .white
                let parts: [(NSRect, NSCompositingOperation, NSColor)] = [
                    (NSRect(x: 0, y: 0, width: edge, height: size.height), tint == .normal ? .clear : .sourceOver, onFill),
                    (NSRect(x: edge, y: 0, width: size.width - edge, height: size.height), .sourceOver, color)]
                for (clip, op, c) in parts {
                    NSGraphicsContext.saveGraphicsState()
                    clip.clip()
                    NSGraphicsContext.current?.compositingOperation = op
                    string(c).draw(at: origin)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            return true
        }
        image.isTemplate = tint == .normal
        return image
    }
}
