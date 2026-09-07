import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let settings: SettingsStore
    private let monitor: GlobalShortcutMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore, monitor: GlobalShortcutMonitor, onOpenSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.settings = settings
        self.monitor = monitor
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        super.init()
        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: "rectangle.3.group.fill", accessibilityDescription: "Taber")
        button?.target = self
        button?.action = #selector(togglePopover)
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button?.setAccessibilityIdentifier("taber.statusItem")
        monitor.$state.sink { [weak self] state in self?.statusItem.button?.toolTip = "Taber — \(state.title)" }.store(in: &cancellables)
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: QuickSettingsView(settings: settings, monitor: monitor, onOpenSettings: { [weak self] in self?.openSettings() }, onQuit: { [weak self] in self?.quit() }))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            for (title, action, key) in [
                (settings.shortcutEnabled ? "Pausar Taber" : "Ativar Taber", #selector(toggleShortcut), ""),
                ("Configurações…", #selector(openSettings), ","),
                ("Encerrar Taber", #selector(quit), "q")
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.target = self
                menu.addItem(item)
            }
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func toggleShortcut() { settings.shortcutEnabled.toggle() }
    @objc private func openSettings() { popover.performClose(nil); onOpenSettings() }
    @objc private func quit() { popover.performClose(nil); onQuit() }
}

struct QuickSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: GlobalShortcutMonitor
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    private var palette: TaberThemePalette { settings.appTheme.palette }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Taber").font(.system(size: 16, weight: .semibold))
                    Text(monitor.state == .active ? "Pronto para alternar" : monitor.state == .disabled ? "Pausado" : "Precisa de atenção")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Spacer()
                Toggle("Ativar Taber", isOn: $settings.shortcutEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Visual").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
                HStack(spacing: 6) {
                    ForEach(SwitcherStyle.allCases) { style in
                        Button { settings.switcherStyle = style } label: {
                            VStack(spacing: 6) {
                                StyleMiniature(style: style).frame(height: 28)
                                Text(style.shortTitle).font(.system(size: 9, weight: .medium))
                            }.frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(TaberChoiceSurface(selected: settings.switcherStyle == style, radius: 8))
                        }.buttonStyle(.plain).accessibilityLabel(style.shortTitle)
                            .accessibilityAddTraits(settings.switcherStyle == style ? .isSelected : [])
                    }
                }
            }
            VStack(spacing: 14) {
                Picker("Tema", selection: $settings.appTheme) { ForEach(AppTheme.allCases) { Text($0.title).tag($0) } }
                Picker("Tamanho", selection: $settings.switcherSize) { ForEach(SwitcherSize.allCases) { Text($0.title).tag($0) } }
            }.pickerStyle(.menu).font(.system(size: 12))
            if monitor.state == .needsAccessibility || monitor.state == .failed {
                Button(action: onOpenSettings) { Label("Revisar permissões", systemImage: "exclamationmark.circle") }
                    .foregroundStyle(palette.accent)
            }
            Divider()
            HStack {
                Button("Configurações…", action: onOpenSettings).keyboardShortcut(",").accessibilityIdentifier("quick.settings")
                Spacer()
                Button(action: onQuit) { Image(systemName: "power") }.help("Encerrar Taber").accessibilityLabel("Encerrar Taber").keyboardShortcut("q")
            }.buttonStyle(.plain).font(.system(size: 12))
        }
        .padding(20).frame(width: 320)
        .foregroundStyle(palette.primary).tint(palette.accent)
        .background(TaberSurfaceBackground(color: palette.panel))
        .environment(\.taberThemePalette, palette)
        .preferredColorScheme(settings.appTheme.colorScheme)
        .environment(\.colorScheme, settings.appTheme.colorScheme)
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }
}
