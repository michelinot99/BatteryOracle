// Renders docs/menubar.png: the menu bar battery in its states, on a light and a dark menu bar.
// Run with: ./scripts/render-menubar.sh
import AppKit

let states: [(label: String, level: Double, charging: Bool, tint: BatteryTint)] = [
    ("100%", 100, false, .normal), ("76%", 76, false, .normal), ("42%", 42, false, .normal),
    ("in carica", 63, true, .normal), ("risparmio", 55, false, .lowPower), ("sotto soglia", 9, false, .low),
]
let scale: CGFloat = 4, cell: CGFloat = 78, rowH: CGFloat = 44
let size = NSSize(width: cell * CGFloat(states.count), height: rowH * 2)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

for (row, dark) in [(1, false), (0, true)] {
    let y = CGFloat(row) * rowH
    (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
    NSRect(x: 0, y: y, width: size.width, height: rowH).fill()
    let ink: NSColor = dark ? .white : .black
    for (i, s) in states.enumerated() {
        let icon = MenuBarBattery.image(level: s.level, charging: s.charging, showPercent: true, tint: s.tint)
        // Template icons are recolored by macOS; do the same here.
        let drawn = icon.isTemplate ? NSImage(size: icon.size, flipped: false) { r in
            icon.draw(in: r)
            ink.setFill()
            r.fill(using: .sourceIn)
            return true
        } : icon
        let x = CGFloat(i) * cell + (cell - icon.size.width) / 2
        drawn.draw(at: NSPoint(x: x, y: y + 20), from: .zero, operation: .sourceOver, fraction: 1)
        let label = NSAttributedString(string: s.label, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: ink.withAlphaComponent(0.55)])
        label.draw(at: NSPoint(x: CGFloat(i) * cell + (cell - label.size().width) / 2, y: y + 6))
    }
}
NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/menubar.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
