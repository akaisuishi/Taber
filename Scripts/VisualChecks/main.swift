import AppKit
import SwiftUI

@main
struct VisualChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/taber-visuals", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "com.taber.visualchecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let panel = SwitcherPanelController()
        let monitor = GlobalShortcutMonitor(windowManager: WindowManager(), settings: settings, panelController: panel)
        if let icon = NSImage(contentsOfFile: "Sources/Taber/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png") { app.applicationIconImage = icon }
        var count = 0
        for theme in AppTheme.allCases {
            settings.appTheme = theme
            for section in SettingsSection.allCases {
                settings.settingsSection = section.rawValue
                try render(SettingsView(settings: settings, monitor: monitor, onRequestAccessibility: {}, onRequestScreenRecording: {}, onPreviewStyle: { _ in }), size: CGSize(width: 880, height: 660), to: output.appendingPathComponent("settings-\(section.rawValue)-\(theme.rawValue).png"))
                count += 1
            }
            try render(QuickSettingsView(settings: settings, monitor: monitor, onOpenSettings: {}, onQuit: {}), size: CGSize(width: 320, height: 366), to: output.appendingPathComponent("menu-\(theme.rawValue).png"))
            count += 1
            for style in SwitcherStyle.allCases {
                for emptySearch in [false, true] {
                    let model = SwitcherViewModel()
                    model.isDemo = true
                    let windows = emptySearch ? [] : WindowInfo.demoWindows
                    model.present(windows: windows, selectedIndex: 0, style: style, theme: theme, size: .large)
                    if emptySearch {
                        model.updateSearch(windows: [], selectedIndex: 0, query: "nenhum resultado", isSearching: true)
                        model.setSearchDetached()
                    }
                    try render(SwitcherView(model: model),
                        size: CGSize(width: 640, height: 360),
                        to: output.appendingPathComponent("edge-\(style.rawValue)-\(theme.rawValue)-\(emptySearch ? "empty-search" : "small-screen").png"))
                    count += 1
                }
                for size in SwitcherSize.allCases {
                    for windowCount in [1, 3, 12] {
                        let model = SwitcherViewModel()
                        let windows = (0..<windowCount).map { i in
                            let base = WindowInfo.demoWindows[i % 3]
                            return WindowInfo(id: UInt32(i + 1), ownerPID: -1, bundleIdentifier: base.bundleIdentifier, applicationName: base.applicationName, title: windowCount == 12 ? "\(base.title) — um título muito longo para verificar truncamento e alinhamento \(i)" : base.title, bounds: base.bounds, isOnScreen: true, isMinimized: false, spaceNumber: 1, icon: base.icon)
                        }
                        model.isDemo = true
                        model.present(windows: windows, selectedIndex: min(1, windows.count - 1), style: style, theme: theme, size: size)
                        let requested = SwitcherPanelController.requestedSize(for: style, windows: windows, metrics: SwitcherMetrics(size: size), isSearching: false)
                        let fitted = CGSize(width: min(requested.width, 1152), height: min(requested.height, 720))
                        try render(SwitcherView(model: model), size: fitted, to: output.appendingPathComponent("switcher-\(style.rawValue)-\(theme.rawValue)-\(size.rawValue)-\(windowCount).png"))
                        count += 1
                    }
                }
            }
        }
        print("Rendered \(count) fixture-only views to \(output.path)")
    }

    @MainActor static func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        hosting.frame = CGRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        window.orderOut(nil)
    }
}
