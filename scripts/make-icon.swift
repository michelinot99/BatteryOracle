// Renders the app icon: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS icon grid: 824 pt squircle centred in 1024.
    let inset = rect.insetBy(dx: 100, dy: 100)
    let shape = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.78, blue: 0.55, alpha: 1),
                        NSColor(red: 0.02, green: 0.42, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: -60)

    // Soft highlight at the top, like a glass sheen.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), .clear])!
        .draw(in: NSRect(x: inset.minX, y: inset.midY, width: inset.width, height: inset.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    func symbol(_ name: String, _ pt: CGFloat, _ weight: NSFont.Weight, at center: CGPoint, alpha: CGFloat = 1) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
        guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        s.draw(in: NSRect(x: center.x - s.size.width / 2, y: center.y - s.size.height / 2,
                          width: s.size.width, height: s.size.height))
    }
    symbol("battery.75percent", 330, .medium, at: CGPoint(x: 500, y: 470))
    symbol("sparkles", 190, .semibold, at: CGPoint(x: 700, y: 690), alpha: 0.95)
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
