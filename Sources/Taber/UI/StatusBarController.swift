import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let settings: SettingsStore
    private let monitor: GlobalShortcutMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: SettingsStore,
        monitor: GlobalShortcutMonitor,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.settings = settings
        self.monitor = monitor
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.3.group.fill",
            accessibilityDescription: "Taber"
        )
        monitor.$state.sink { [weak self] state in
            self?.statusItem.button?.toolTip = "Taber — \(state.title)"
        }.store(in: &cancellables)
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let title = NSMenuItem(title: "Taber", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let status = NSMenuItem(title: monitor.state.title, action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: monitor.state.symbolName, accessibilityDescription: nil)
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let enabledItem = NSMenuItem(
            title: settings.shortcutEnabled ? "Desativar Command + Tab" : "Ativar Command + Tab",
            action: #selector(toggleShortcut),
            keyEquivalent: ""
        )
        enabledItem.target = self
        menu.addItem(enabledItem)

        let appearanceMenu = NSMenu()
        for style in SwitcherStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = settings.switcherStyle == style ? .on : .off
            appearanceMenu.addItem(item)
        }
        let appearanceItem = NSMenuItem(title: "Visual", action: nil, keyEquivalent: "")
        menu.setSubmenu(appearanceMenu, for: appearanceItem)
        menu.addItem(appearanceItem)

        let themeMenu = NSMenu()
        for theme in AppTheme.allCases {
            let item = NSMenuItem(title: theme.title, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            item.state = settings.appTheme == theme ? .on : .off
            themeMenu.addItem(item)
        }
        let themeItem = NSMenuItem(title: "Tema", action: nil, keyEquivalent: "")
        menu.setSubmenu(themeMenu, for: themeItem)
        menu.addItem(themeItem)

        let settingsItem = NSMenuItem(title: "Configurações…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Encerrar Taber", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func toggleShortcut() {
        settings.shortcutEnabled.toggle()
        rebuildMenu()
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let style = SwitcherStyle(rawValue: rawValue) else { return }
        settings.switcherStyle = style
        rebuildMenu()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let theme = AppTheme(rawValue: rawValue) else { return }
        settings.appTheme = theme
        rebuildMenu()
    }

    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
}
