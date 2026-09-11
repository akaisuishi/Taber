import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore(defaults: ProcessInfo.processInfo.arguments.contains("--ui-testing")
        ? UserDefaults(suiteName: "com.taber.ui-testing")! : .standard)
    private let windowManager = WindowManager()
    private var statusBarController: StatusBarController!
    private var shortcutMonitor: GlobalShortcutMonitor!
    private var switcherPanelController: SwitcherPanelController!
    private var settingsWindowController: SettingsWindowController?
    private var previewHideWorkItem: DispatchWorkItem?
    private var registeredSettingsWindowNumber: CGWindowID?
    private var registeredSettingsIdentity: WindowIdentity?
    private var applicationResignObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        if isUITesting { settings.shortcutEnabled = false }
        configureMainMenu()
        switcherPanelController = SwitcherPanelController()
        shortcutMonitor = GlobalShortcutMonitor(
            windowManager: windowManager,
            settings: settings,
            panelController: switcherPanelController,
            additionalWindows: { [weak self] in
                self?.settingsWindowSnapshot().map { [$0] } ?? []
            }
        )
        statusBarController = StatusBarController(
            settings: settings,
            monitor: shortcutMonitor,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) },
            onWillPresentOverlay: { [weak self] in self?.prepareForStatusOverlay() }
        )
        shortcutMonitor.onCycleWillStart = { [weak self] in
            self?.prepareForLiveCycle()
        }
        applicationResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPreview() }
        }
        if isUITesting { openSettings() } else { shortcutMonitor.start() }

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
        statusBarController?.dismissPopover()
        shortcutMonitor?.cancelCycle()
        cancelPreview()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                monitor: shortcutMonitor,
                onRequestAccessibility: { AccessibilityService.openAccessibilitySettings() },
                onRequestScreenRecording: { AccessibilityService.openScreenRecordingSettings() },
                onPreviewStyle: { [weak self] style in self?.previewSwitcher(style: style) },
                onWindowStateChange: { [weak self] window in
                    self?.registerSettingsWindow(window)
                },
                onDismissPreview: { [weak self] in self?.cancelPreview() }
            )
        }

        settingsWindowController?.activateSettingsWindow()
    }

    private func previewSwitcher(style: SwitcherStyle) {
        statusBarController?.dismissPopover()
        shortcutMonitor.cancelCycle()
        cancelPreview()
        switcherPanelController.show(
            windows: WindowInfo.demoWindows,
            selectedIndex: 1,
            style: style,
            theme: settings.appTheme,
            size: settings.switcherSize,
            transparencyEnabled: settings.transparencyEnabled,
                transparencyPercent: settings.transparencyPercent,
            isDemo: true
        )

        let workItem = DispatchWorkItem { [weak self] in
            self?.switcherPanelController.hideDemo()
        }
        previewHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: workItem)
    }

    private func prepareForStatusOverlay() {
        shortcutMonitor.cancelCycle()
        cancelPreview()
    }

    private func prepareForLiveCycle() {
        statusBarController?.dismissPopover()
        cancelPreview()
    }

    private func cancelPreview() {
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
        switcherPanelController?.hideDemo()
    }

    private func settingsWindowSnapshot() -> WindowInfo? {
        guard let controller = settingsWindowController,
              let window = controller.window,
              let registeredSettingsWindowNumber,
              registeredSettingsWindowNumber == CGWindowID(window.windowNumber),
              window.isVisible || window.isMiniaturized
        else { return nil }

        return WindowInfo(
            id: registeredSettingsWindowNumber,
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.taber.app",
            applicationName: "Taber",
            title: "Configurações",
            bounds: window.frame,
            isOnScreen: window.isVisible && !window.isMiniaturized,
            isMinimized: window.isMiniaturized,
            activationMode: .raiseWindow,
            screenName: window.screen?.localizedName ?? "",
            icon: NSApp.applicationIconImage,
            accessibilityIdentifier: "taber.settings",
            accessibilityOrdinal: 0,
            isAccessibilityFocused: window.isKeyWindow,
            processLaunchDate: NSRunningApplication.current.launchDate
        )
    }

    private func registerSettingsWindow(_ window: NSWindow?) {
        if let registeredSettingsIdentity {
            AccessibilityService.unregisterLocalWindow(id: registeredSettingsIdentity)
        }
        registeredSettingsWindowNumber = nil
        registeredSettingsIdentity = nil

        guard let window else { return }
        let windowNumber = CGWindowID(window.windowNumber)
        let identity = WindowIdentity.windowServer(
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            launchDate: NSRunningApplication.current.launchDate,
            id: windowNumber
        )
        registeredSettingsWindowNumber = windowNumber
        registeredSettingsIdentity = identity
        AccessibilityService.registerLocalWindow(id: identity) { [weak self] in
            guard let controller = self?.settingsWindowController,
                  controller.window?.windowNumber == Int(windowNumber)
            else { return false }
            controller.activateSettingsWindow()
            return true
        }
    }
}
