import AppKit
import Combine
@preconcurrency import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore(defaults: ProcessInfo.processInfo.arguments.contains("--ui-testing")
        ? UserDefaults(suiteName: "com.taber.ui-testing")! : .standard)
    private let windowManager = WindowManager()
    private let windowHistory = WindowRecencyHistory()
    private var windowTracking: WindowTrackingService?
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
            history: windowHistory,
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
        if isUITesting { openSettings() } else {
            AccessibilityService.onTargetConfirmed = { [weak self] window in
                guard let self else { return }
                if let wid = window.presentationWindowID ?? window.windowServerID {
                    self.windowHistory.observe(
                        pid: window.activationPID,
                        birth: window.activationProcessLaunchDate,
                        windowID: wid,
                        windows: self.windowManager.windows
                    )
                } else {
                    self.windowHistory.touch(window.id)
                }
                self.windowTracking?.scheduleImmediateRefresh()
            }
            windowTracking = WindowTrackingService(
                manager: windowManager,
                settings: settings,
                history: windowHistory,
                additionalWindows: { [weak self] in
                    self?.settingsWindowSnapshot().map { [$0] } ?? []
                }
            )
            windowTracking?.start()
            shortcutMonitor.start()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.shortcutMonitor.state != .active else { return }
            self.openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { windowTracking?.stop() }

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

// Recency is based on observed focus, never on a requested (possibly failed) activation.
@MainActor
final class WindowRecencyHistory {
    private var sequence: UInt64 = 0
    private var stamps: [WindowIdentity: UInt64] = [:]
    private var observedFocus: (pid: pid_t, birth: Date?, windowID: CGWindowID)?
    func touch(_ id: WindowIdentity) { sequence &+= 1; stamps[id] = sequence }
    func observe(pid: pid_t, birth: Date?, windowID: CGWindowID, windows: [WindowInfo]) {
        observedFocus = (pid, birth, windowID)
        let matched = current(in: windows, frontmostPID: pid, launchDate: birth)
        touch(matched?.id ?? .windowServer(ownerPID: pid, launchDate: birth, id: windowID))
    }
    func current(in windows: [WindowInfo], frontmostPID: pid_t?, launchDate: Date?) -> WindowInfo? {
        guard let observedFocus, observedFocus.pid == frontmostPID,
              observedFocus.birth == launchDate else { return nil }
        let matches = windows.filter {
            $0.activationPID == frontmostPID && $0.activationProcessLaunchDate == launchDate
                && ($0.windowServerID == observedFocus.windowID || $0.presentationWindowID == observedFocus.windowID)
        }
        guard matches.count == 1 else { return nil }
        let matched = matches[0]
        if !matched.isOnScreen {
            let onScreenFullScreen = windows.filter {
                $0.activationPID == frontmostPID && $0.activationProcessLaunchDate == launchDate
                    && $0.isOnScreen && $0.isFullScreen
            }
            if onScreenFullScreen.count == 1 {
                let player = onScreenFullScreen[0]
                if (stamps[player.id] ?? 0) <= (stamps[matched.id] ?? 0) {
                    touch(player.id)
                }
                return player
            }
        }
        return matched
    }
    func purge(keeping identities: Set<WindowIdentity>) { stamps = stamps.filter { identities.contains($0.key) } }
    func ordered(_ windows: [WindowInfo], current: WindowInfo?) -> [WindowInfo] {
        let deprioritizedHostID: WindowIdentity? = {
            guard let current, current.isFullScreen else { return nil }
            let isDetachedUntitledPlayer = (current.presentationWindowID != nil && current.windowServerID == current.presentationWindowID)
                || (current.presentationWindowID == nil && current.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            guard isDetachedUntitledPlayer else { return nil }
            let offScreenSiblings = windows.filter {
                $0.ownerPID == current.ownerPID && !$0.isOnScreen && !$0.isFullScreen && !$0.isMinimized
            }
            if let observedFocus,
               observedFocus.pid == current.activationPID,
               observedFocus.birth == current.activationProcessLaunchDate,
               let observedHost = offScreenSiblings.first(where: { $0.windowServerID == observedFocus.windowID }) {
                return observedHost.id
            }
            return offScreenSiblings.count == 1 ? offScreenSiblings[0].id : nil
        }()
        return windows.enumerated().sorted { lhs, rhs in
            if lhs.element.id == current?.id { return rhs.element.id != current?.id }
            if rhs.element.id == current?.id { return false }
            if let hostID = deprioritizedHostID {
                let lhsIsOffScreenHost = lhs.element.id == hostID
                let rhsIsOffScreenHost = rhs.element.id == hostID
                if lhsIsOffScreenHost != rhsIsOffScreenHost {
                    return !lhsIsOffScreenHost
                }
            }
            let a = stamps[lhs.element.id] ?? 0, b = stamps[rhs.element.id] ?? 0
            return a == b ? lhs.offset < rhs.offset : a > b
        }.map(\.element)
    }
}

@MainActor
final class WindowTrackingService {
    private let manager: WindowManager
    private let settings: SettingsStore
    private let history: WindowRecencyHistory
    private let additionalWindows: () -> [WindowInfo]
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var refreshWork: DispatchWorkItem?
    private var spaceSettleWork: DispatchWorkItem?
    private var sessionAvailable = true
    private var running = false

    init(manager: WindowManager, settings: SettingsStore, history: WindowRecencyHistory,
         additionalWindows: @escaping () -> [WindowInfo] = { [] }) {
        self.manager = manager; self.settings = settings; self.history = history
        self.additionalWindows = additionalWindows
        manager.onTrackingSnapshot = { [weak self] windows in
            self?.handleCompletedSnapshot(windows)
        }
    }
    private func handleCompletedSnapshot(_ windows: [WindowInfo]) {
        history.purge(keeping: Set((windows + additionalWindows()).map(\.id)))
        if running, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            observeFocus(pid: pid)
        }
    }
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let notificationPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                let isSpaceChange = note.name == NSWorkspace.activeSpaceDidChangeNotification
                let terminated = note.name == NSWorkspace.didTerminateApplicationNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let pid = notificationPID ?? (isSpaceChange ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil)
                    if let pid {
                        if terminated {
                            self.detach(pid)
                            AXWindowReferenceCache.shared.remove(ownerPID: pid)
                        } else if self.running, let app = NSRunningApplication(processIdentifier: pid) {
                            self.attach(app)
                            self.observeFocus(pid: pid)
                        }
                    }
                    self.requestRefresh()
                    if isSpaceChange {
                        self.spaceSettleWork?.cancel()
                        let settle = DispatchWorkItem { [weak self] in
                            self?.requestRefresh()
                        }
                        self.spaceSettleWork = settle
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: settle)
                    }
                }
            })
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let available = note.name == NSWorkspace.sessionDidBecomeActiveNotification || note.name == NSWorkspace.didWakeNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sessionAvailable = available
                    self.updateLifecycle()
                }
            })
        }
        settings.$shortcutEnabled.combineLatest(settings.$includeUtilityWindows)
            .dropFirst().sink { [weak self] enabled, _ in
                // Published emits before storage changes; use the emitted enabled value.
                self?.updateLifecycle(enabled: enabled)
            }.store(in: &subscriptions)
        updateLifecycle()
    }
    func stop() {
        running = false; timer?.invalidate(); timer = nil
        refreshWork?.cancel(); refreshWork = nil
        spaceSettleWork?.cancel(); spaceSettleWork = nil
        for pid in Array(observers.keys) { detach(pid) }
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll(); subscriptions.removeAll(); manager.suspend()
    }
    private func updateLifecycle(enabled: Bool? = nil) {
        let shouldRun = (enabled ?? settings.shortcutEnabled) && sessionAvailable
        running = shouldRun
        if shouldRun {
            manager.resume()
            for app in NSWorkspace.shared.runningApplications { attach(app) }
            if timer == nil {
                let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.requestRefresh() }
                }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            requestRefresh()
        } else {
            timer?.invalidate(); timer = nil; refreshWork?.cancel(); refreshWork = nil
            spaceSettleWork?.cancel(); spaceSettleWork = nil
            for pid in Array(observers.keys) { detach(pid) }
            manager.suspend(); AccessibilityService.cancelPendingRestoration()
        }
    }
    func scheduleImmediateRefresh() {
        requestRefresh()
    }
    private func requestRefresh() {
        guard running else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.manager.requestRefresh(includeUtilityWindows: self.settings.includeUtilityWindows)
        }
        refreshWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier, observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let service = Unmanaged<WindowTrackingService>.fromOpaque(context).takeUnretainedValue()
                if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { service.observeFocus(pid: pid) }
                service.requestRefresh()
            }
        }, &observer) == .success, let observer else { return }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.01)
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(observer, root, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    private func observeFocus(pid: pid_t) {
        guard running, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root, 0.01)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let window = value as! AXUIElement; AXUIElementSetMessagingTimeout(window, 0.01)
            if let id = AccessibilityWindowIdentityResolver.windowID(for: window) {
                AXWindowReferenceCache.shared.store(window, ownerPID: pid, launchDate: app.launchDate, windowID: id)
                if let pending = AccessibilityService.pendingTargetWindow,
                   pending.activationPID == pid,
                   id != pending.windowServerID,
                   id != pending.presentationWindowID {
                    return
                }
                history.observe(pid: pid, birth: app.launchDate, windowID: id, windows: manager.windows)
                return
            }
        }
        if let pending = AccessibilityService.pendingTargetWindow, pending.activationPID == pid {
            return
        }
        let onScreenWindows = manager.windows.filter {
            $0.activationPID == pid && $0.isOnScreen && !$0.isMinimized
        }
        if onScreenWindows.count == 1,
           let id = onScreenWindows[0].presentationWindowID ?? onScreenWindows[0].windowServerID {
            history.observe(pid: pid, birth: app.launchDate, windowID: id, windows: manager.windows)
        }
    }
}
