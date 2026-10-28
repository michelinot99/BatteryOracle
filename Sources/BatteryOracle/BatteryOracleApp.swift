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
        let warn = m.outlook?.verdict == .charger && m.battery?.plugged == false
        Image(nsImage: MenuBarBattery.image(level: m.battery?.level ?? 0, charging: m.battery?.charging == true,
                                            showPercent: m.showPercent, tint: m.batteryTint, warning: warn))
            .onAppear { PreviewWindow.showIfRequested(m) }
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
        let root = CommandLine.arguments.contains("--settings") ? AnyView(SettingsView(m: m).padding(16)) : AnyView(PopoverView(m: m))
        let host = NSHostingView(rootView: root.padding(.top, 18)
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
                let renderer = ImageRenderer(content: root.frame(width: 372)
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

/// Settings live in a regular window: a long form doesn't belong in a menu bar popover,
/// whose height is fixed when it opens.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(_ m: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Impostazioni di BatteryOracle"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView(m: m)
                .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 36)
                .frame(width: 400))
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
