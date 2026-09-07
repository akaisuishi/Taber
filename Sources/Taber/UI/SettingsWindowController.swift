import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        settings: SettingsStore,
        monitor: GlobalShortcutMonitor,
        onRequestAccessibility: @escaping () -> Void,
        onRequestScreenRecording: @escaping () -> Void,
        onPreviewStyle: @escaping (SwitcherStyle) -> Void
    ) {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
