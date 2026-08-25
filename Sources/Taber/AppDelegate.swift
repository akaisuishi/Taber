import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let windowManager = WindowManager()
    private var statusBarController: StatusBarController!
    private var shortcutMonitor: GlobalShortcutMonitor!
    private var switcherPanelController: SwitcherPanelController!
    private var settingsWindowController: SettingsWindowController?
    private var previewHideWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        switcherPanelController = SwitcherPanelController()
        shortcutMonitor = GlobalShortcutMonitor(
            windowManager: windowManager,
            settings: settings,
            panelController: switcherPanelController
        )
        statusBarController = StatusBarController(
            settings: settings,
            monitor: shortcutMonitor,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        shortcutMonitor.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.shortcutMonitor.state != .active else { return }
            self.openSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: "Menu principal")

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Taber")
        applicationMenu.addItem(
            withTitle: "Configurações…",
            action: #selector(openSettingsFromMainMenu),
            keyEquivalent: ","
        ).target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Ocultar Taber",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Encerrar Taber",
            action: #selector(terminateFromMainMenu),
            keyEquivalent: "q"
        ).target = self
        mainMenu.setSubmenu(applicationMenu, for: applicationMenuItem)
        mainMenu.addItem(applicationMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Janela")
        windowMenu.addItem(
            withTitle: "Fechar Janela",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "Minimizar",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        mainMenu.setSubmenu(windowMenu, for: windowMenuItem)
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openSettingsFromMainMenu() {
        openSettings()
    }

    @objc private func terminateFromMainMenu() {
        NSApp.terminate(nil)
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                monitor: shortcutMonitor,
                onRequestAccessibility: { AccessibilityService.openAccessibilitySettings() },
                onRequestScreenRecording: { AccessibilityService.openScreenRecordingSettings() },
                onPreviewStyle: { [weak self] style in self?.previewSwitcher(style: style) }
            )
        }

        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func previewSwitcher(style: SwitcherStyle) {
        windowManager.refresh(includeUtilityWindows: settings.includeUtilityWindows)
        guard !windowManager.windows.isEmpty else { return }

        previewHideWorkItem?.cancel()
        switcherPanelController.show(
            windows: windowManager.windows,
            selectedIndex: min(1, windowManager.windows.count - 1),
            style: style,
            theme: settings.appTheme,
            size: settings.switcherSize
        )

        let workItem = DispatchWorkItem { [weak self] in
            self?.switcherPanelController.hide()
        }
        previewHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: workItem)
    }
}
