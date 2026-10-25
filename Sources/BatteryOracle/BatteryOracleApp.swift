import SwiftUI

@main
struct BatteryOracleApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(m: model)
                .onAppear { model.popoverOpen = true }
                .onDisappear { model.popoverOpen = false }
        } label: {
            MenuBarLabel(m: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var m: AppModel

    var body: some View {
        let level = m.battery?.level ?? 0
        let warn = m.outlook?.verdict == .charger && m.battery?.plugged == false
        HStack(spacing: 3) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : symbol(level))
            if m.showPercent { Text("\(Int(level))%").monospacedDigit() }
        }
        .onAppear { PreviewWindow.showIfRequested(m) }
    }

    private func symbol(_ level: Double) -> String {
        if m.battery?.charging == true { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// `--window` shows the popover in a regular window, handy for screenshots and UI work.
@MainActor
enum PreviewWindow {
    private static var window: NSWindow?

    static func showIfRequested(_ m: AppModel) {
        guard window == nil, CommandLine.arguments.contains("--window") else { return }
        let snapshot = CommandLine.arguments.firstIndex(of: "--snapshot")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // Offscreen captures can't render vibrancy, so snapshots get a solid popover-like backdrop.
        let effect: NSView
        if snapshot == nil {
            let v = NSVisualEffectView()
            v.material = .popover
            v.state = .active
            effect = v
        } else {
            effect = NSView()
            effect.wantsLayer = true
            effect.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
            w.appearance = NSAppearance(named: .darkAqua)
        }
        let host = NSHostingView(rootView: PopoverView(m: m).padding(.top, 18)
            .background(snapshot == nil ? Color.clear : Color(white: 0.14))
            .preferredColorScheme(snapshot == nil ? nil : .dark))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        w.contentView = effect
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardOutput.write(Data("window \(w.windowNumber)\n".utf8))
        window = w

        // `--snapshot <file.png>` saves the window once the forecast has landed, then quits.
        if let i = snapshot, i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let renderer = ImageRenderer(content: PopoverView(m: m)
                    .background(Color(white: 0.12))
                    .environment(\.colorScheme, .dark))
                renderer.scale = 2
                if let cg = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }
}
