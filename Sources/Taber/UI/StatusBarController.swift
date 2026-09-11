import AppKit
import Combine
import SwiftUI

@MainActor
final class QuickSettingsLayout: ObservableObject {
    @Published var maximumSize = NSSize(width: 320, height: 600)
    @Published var contentHeight: CGFloat = 520
    var viewportSize: NSSize {
        NSSize(width: maximumSize.width, height: min(contentHeight, maximumSize.height))
    }
    static func availableSize(anchor: NSRect, visibleFrame: NSRect) -> NSSize {
        // Reserve room below the menu-bar anchor for the arrow and screen margin.
        NSSize(width: max(1, min(320, visibleFrame.width - 16)),
               height: max(1, min(anchor.minY, visibleFrame.maxY) - visibleFrame.minY - 24))
    }
}

private struct QuickSettingsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 520
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let settings: SettingsStore
    private let monitor: GlobalShortcutMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let layout = QuickSettingsLayout()
    private let contextMenu = NSMenu(title: "Taber")
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let onWillPresentOverlay: () -> Void
    private var cancellables = Set<AnyCancellable>()
    nonisolated(unsafe) private var workspaceActivationObserver: NSObjectProtocol?

    init(
        settings: SettingsStore,
        monitor: GlobalShortcutMonitor,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onWillPresentOverlay: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.monitor = monitor
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onWillPresentOverlay = onWillPresentOverlay
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
        popover.contentViewController = NSHostingController(rootView: QuickSettingsView(settings: settings, monitor: monitor, layout: layout, onOpenSettings: { [weak self] in self?.openSettings() }, onQuit: { [weak self] in self?.quit() }, onDismiss: { [weak self] in self?.popover.performClose(nil) }))
        layout.$contentHeight.removeDuplicates().sink { [weak self] height in
            guard let self else { return }
            self.popover.contentSize = NSSize(width: self.layout.maximumSize.width,
                height: min(height, self.layout.maximumSize.height))
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.updateAvailableSize() }.store(in: &cancellables)
        configureContextMenu()
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            MainActor.assumeIsolated { self?.dismissPopover() }
        }
    }

    deinit {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            dismissPopover()
            onWillPresentOverlay()
            contextMenu.popUp(
                positioning: nil,
                at: NSPoint(x: button.bounds.minX, y: button.bounds.minY - 2),
                in: button
            )
        } else if popover.isShown { popover.performClose(nil) }
        else {
            onWillPresentOverlay()
            updateAvailableSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }


    private func updateAvailableSize() {
        guard let button = statusItem.button, let window = button.window,
              let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        layout.maximumSize = QuickSettingsLayout.availableSize(anchor: anchor, visibleFrame: screen.visibleFrame)
        popover.contentSize = layout.viewportSize
    }

    func popoverDidShow(_ notification: Notification) {
        let window = popover.contentViewController?.view.window
        window?.isOpaque = false
        window?.backgroundColor = .clear
        updateAvailableSize()
    }

    func dismissPopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        contextMenu.item(at: 0)?.title = settings.shortcutEnabled ? "Pausar Taber" : "Ativar Taber"
    }

    private func configureContextMenu() {
        contextMenu.delegate = self
        for (title, action, key) in [
            ("Pausar Taber", #selector(toggleShortcut), ""),
            ("Configurações…", #selector(openSettings), ","),
            ("Encerrar Taber", #selector(quit), "q")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            contextMenu.addItem(item)
        }
    }
    @objc private func toggleShortcut() { settings.shortcutEnabled.toggle() }
    @objc private func openSettings() { popover.performClose(nil); onOpenSettings() }
    @objc private func quit() { popover.performClose(nil); onQuit() }
}

struct QuickSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: GlobalShortcutMonitor
    @ObservedObject var layout = QuickSettingsLayout()
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    var onDismiss: () -> Void = {}
    private var palette: TaberThemePalette { settings.appTheme.palette }
    var body: some View {
        ScrollView(.vertical) {
            content
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: QuickSettingsContentHeightKey.self, value: geometry.size.height)
                })
        }
        .frame(width: layout.viewportSize.width, height: layout.viewportSize.height)
        .onPreferenceChange(QuickSettingsContentHeightKey.self) { height in
            if height > 0 && abs(layout.contentHeight - height) > 0.5 { layout.contentHeight = height }
        }
        .foregroundStyle(palette.primary).tint(palette.accent)
        .background(TaberSurfaceBackground(color: palette.panel))
        .environment(\.taberThemePalette, palette)
        .environment(\.taberTransparencyEnabled, settings.transparencyEnabled)
        .environment(\.taberTransparencyPercent, settings.transparencyPercent)
        .preferredColorScheme(settings.appTheme.colorScheme)
        .environment(\.colorScheme, settings.appTheme.colorScheme)
        .onExitCommand(perform: onDismiss)
    }

    private var content: some View {
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
                Toggle("Transparência", isOn: $settings.transparencyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("quick.transparency")
                TransparencyAmountControl(settings: settings, identifier: "quick.transparencyPercent")
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
        .padding(20).frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}
