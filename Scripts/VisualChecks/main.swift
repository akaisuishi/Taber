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
            for (transparencyEnabled, percent) in [(false, 15.0), (true, 0.0), (true, 15.0), (true, 60.0)] {
                settings.transparencyEnabled = transparencyEnabled
                settings.transparencyPercent = percent
                let transparencyName = transparencyEnabled ? "\(Int(percent))" : "off"

                // Configurações e painel rápido também participam da matriz de
                // transparência; todas as seções são preservadas como fixtures.
                for section in SettingsSection.allCases {
                    settings.settingsSection = section.rawValue
                    try render(
                        SettingsView(settings: settings, monitor: monitor, onRequestAccessibility: {}, onRequestScreenRecording: {}, onPreviewStyle: { _ in }),
                        size: CGSize(width: 880, height: 760),
                        to: output.appendingPathComponent("settings-\(section.rawValue)-\(theme.rawValue)-transparency-\(transparencyName).png")
                    )
                    count += 1
                }
                try render(
                    QuickSettingsView(settings: settings, monitor: monitor, onOpenSettings: {}, onQuit: {}),
                    size: CGSize(width: 320, height: 540),
                    to: output.appendingPathComponent("menu-\(theme.rawValue)-transparency-\(transparencyName).png")
                )
                count += 1
                let smallLayout = QuickSettingsLayout()
                smallLayout.maximumSize = NSSize(width: 320, height: 280)
                try render(QuickSettingsView(settings: settings, monitor: monitor, layout: smallLayout,
                    onOpenSettings: {}, onQuit: {}), size: CGSize(width: 320, height: 280),
                    to: output.appendingPathComponent("menu-small-\(theme.rawValue)-transparency-\(transparencyName).png"))
                count += 1

                // Matriz: 4 visuais × 3 temas × 3 tamanhos × OFF/0%/15%/60%.
                for style in SwitcherStyle.allCases {
                    for size in SwitcherSize.allCases {
                        let model = SwitcherViewModel()
                        let windows = fixtureWindows(count: 3)
                        model.isDemo = true
                        model.present(
                            windows: windows,
                            selectedIndex: 1,
                            style: style,
                            theme: theme,
                            size: size,
                            transparencyEnabled: transparencyEnabled,
                            transparencyPercent: percent
                        )
                        let requested = SwitcherPanelController.requestedSize(
                            for: style,
                            windows: windows,
                            metrics: SwitcherMetrics(size: size),
                            isSearching: false
                        )
                        let fitted = CGSize(width: min(requested.width, 1152), height: min(requested.height, 720))
                        try render(
                            SwitcherView(model: model),
                            size: fitted,
                            to: output.appendingPathComponent("switcher-\(style.rawValue)-\(theme.rawValue)-\(size.rawValue)-transparency-\(transparencyName).png")
                        )
                        count += 1
                    }
                }
            }

            // Casos de borda continuam independentes da matriz principal para
            // detectar regressões de busca vazia, tela pequena e volume.
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
                    try render(
                        SwitcherView(model: model),
                        size: CGSize(width: 640, height: 360),
                        to: output.appendingPathComponent("edge-\(style.rawValue)-\(theme.rawValue)-\(emptySearch ? "empty-search" : "small-screen").png")
                    )
                    count += 1
                }
                for size in SwitcherSize.allCases {
                    for windowCount in [1, 12] {
                        let model = SwitcherViewModel()
                        let windows = fixtureWindows(count: windowCount)
                        model.isDemo = true
                        model.present(
                            windows: windows,
                            selectedIndex: min(1, windows.count - 1),
                            style: style,
                            theme: theme,
                            size: size
                        )
                        let requested = SwitcherPanelController.requestedSize(
                            for: style,
                            windows: windows,
                            metrics: SwitcherMetrics(size: size),
                            isSearching: false
                        )
                        let fitted = CGSize(width: min(requested.width, 1152), height: min(requested.height, 720))
                        try render(
                            SwitcherView(model: model),
                            size: fitted,
                            to: output.appendingPathComponent("edge-count-\(style.rawValue)-\(theme.rawValue)-\(size.rawValue)-\(windowCount).png")
                        )
                        count += 1
                    }
                }
            }
        }
        print("Rendered \(count) fixture-only views to \(output.path)")
    }

    @MainActor static func fixtureWindows(count: Int) -> [WindowInfo] {
        (0..<count).map { index in
            let base = WindowInfo.demoWindows[index % WindowInfo.demoWindows.count]
            return WindowInfo(
                id: UInt32(index + 1),
                ownerPID: -1,
                bundleIdentifier: base.bundleIdentifier,
                applicationName: base.applicationName,
                title: count == 12
                    ? "\(base.title) — um título muito longo para verificar truncamento e alinhamento \(index)"
                    : base.title,
                bounds: base.bounds,
                isOnScreen: true,
                isMinimized: false,
                spaceNumber: 1,
                icon: base.icon
            )
        }
    }

    @MainActor static func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
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
