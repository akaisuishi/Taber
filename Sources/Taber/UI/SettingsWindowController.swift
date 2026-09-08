import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let onWindowStateChange: (NSWindow?) -> Void
    private let onDismissPreview: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: SettingsStore,
        monitor: GlobalShortcutMonitor,
        onRequestAccessibility: @escaping () -> Void,
        onRequestScreenRecording: @escaping () -> Void,
        onPreviewStyle: @escaping (SwitcherStyle) -> Void,
        onWindowStateChange: @escaping (NSWindow?) -> Void = { _ in },
        onDismissPreview: @escaping () -> Void = {}
    ) {
        self.onWindowStateChange = onWindowStateChange
        self.onDismissPreview = onDismissPreview
        let view = SettingsView(
            settings: settings,
            monitor: monitor,
            onRequestAccessibility: onRequestAccessibility,
            onRequestScreenRecording: onRequestScreenRecording,
            onPreviewStyle: onPreviewStyle
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Taber"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 880, height: 660))
        window.minSize = NSSize(width: 780, height: 602)
        window.setFrameAutosaveName("TaberSettings")
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)
        window.delegate = self

        settings.$transparencyEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.applyWindowTransparency(preferenceEnabled: enabled) }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )
        .sink { [weak self, weak settings] _ in
            guard let settings else { return }
            self?.applyWindowTransparency(preferenceEnabled: settings.transparencyEnabled)
        }
        .store(in: &cancellables)
        applyWindowTransparency(preferenceEnabled: settings.transparencyEnabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        publishWindowState()
    }

    /// Settings is the only Taber-owned surface that participates in the
    /// switcher. Activation stays in AppKit and never falls through to AX.
    func activateSettingsWindow() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        publishWindowState()
    }

    private func publishWindowState() {
        guard let window,
              window.isVisible || window.isMiniaturized
        else {
            onWindowStateChange(nil)
            return
        }
        onWindowStateChange(window)
    }

    private func applyWindowTransparency(preferenceEnabled: Bool) {
        guard let window else { return }
        let effective = TaberTransparencyPolicy.isEffective(
            userEnabled: preferenceEnabled,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        window.isOpaque = !effective
        window.backgroundColor = effective ? .clear : .windowBackgroundColor
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        publishWindowState()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        onDismissPreview()
        publishWindowState()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        publishWindowState()
    }

    func windowDidResignKey(_ notification: Notification) {
        onDismissPreview()
    }

    func windowWillClose(_ notification: Notification) {
        onDismissPreview()
        onWindowStateChange(nil)
    }
}
