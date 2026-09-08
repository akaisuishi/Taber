import AppKit
import Combine
import CoreGraphics
import os

private let tabKeyCode: Int64 = 48
private let returnKeyCode: Int64 = 36
private let deleteKeyCode: Int64 = 51
private let escapeKeyCode: Int64 = 53
private let leftShiftKeyCode: Int64 = 56
private let rightShiftKeyCode: Int64 = 60
private let leftArrowKeyCode: Int64 = 123
private let rightArrowKeyCode: Int64 = 124
private let downArrowKeyCode: Int64 = 125
private let upArrowKeyCode: Int64 = 126

private let directionalKeyCodes: Set<Int64> = [
    leftArrowKeyCode,
    rightArrowKeyCode,
    downArrowKeyCode,
    upArrowKeyCode
]

private let shiftKeyCodes: Set<Int64> = [leftShiftKeyCode, rightShiftKeyCode]

private func keyboardText(from event: CGEvent) -> String {
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 16)
    buffer.withUnsafeMutableBufferPointer { pointer in
        event.keyboardGetUnicodeString(
            maxStringLength: pointer.count,
            actualStringLength: &length,
            unicodeString: pointer.baseAddress
        )
    }
    guard length > 0 else { return "" }
    return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
}

private extension CGEventTapLocation {
    var taberDescription: String {
        switch self {
        case .cghidEventTap: "HID"
        case .cgSessionEventTap: "sessão"
        case .cgAnnotatedSessionEventTap: "sessão anotada"
        @unknown default: "desconhecido"
        }
    }
}

private func taberEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { monitor.handleEventTapDisabled() }
        return Unmanaged.passUnretained(event)
    }

    if (type == .leftMouseDown || type == .rightMouseDown),
       monitor.isSearchDetachedForEventTap {
        DispatchQueue.main.async { monitor.cancelCycle() }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let commandPressed = event.flags.contains(.maskCommand)

    if type == .keyDown, commandPressed, keyCode == tabKeyCode {
        let reverse = event.flags.contains(.maskShift)
        DispatchQueue.main.async { monitor.beginOrAdvanceCycle(reverse: reverse) }
        return nil
    }

    if type == .keyDown,
       keyCode == escapeKeyCode,
       (commandPressed || monitor.isSearchActiveForEventTap),
       monitor.isCycleActiveForEventTap {
        DispatchQueue.main.async { monitor.handleEscape() }
        return nil
    }

    if type == .flagsChanged,
       commandPressed,
       event.flags.contains(.maskShift),
       shiftKeyCodes.contains(keyCode),
       monitor.isCycleActiveForEventTap,
       !monitor.isSearchActiveForEventTap,
       monitor.searchShortcutForEventTap == .doubleShift {
        DispatchQueue.main.async { monitor.handleSearchShiftPress() }
    }

    if commandPressed,
       monitor.isCycleActiveForEventTap,
       !monitor.isSearchActiveForEventTap,
       monitor.searchShortcutForEventTap.keyCode == keyCode {
        if type == .keyDown {
            DispatchQueue.main.async { monitor.enterSearch() }
        }
        return nil
    }

    if (commandPressed || monitor.isSearchActiveForEventTap),
       directionalKeyCodes.contains(keyCode),
       monitor.isCycleActiveForEventTap {
        if type == .keyDown {
            DispatchQueue.main.async { monitor.navigate(using: keyCode) }
        }
        // Enquanto o alternador estiver aberto, nenhuma seta deve escapar
        // para o aplicativo abaixo e acionar Command + seta por acidente.
        return nil
    }

    if !commandPressed,
       monitor.isSearchActiveForEventTap,
       keyCode == tabKeyCode,
       (type == .keyDown || type == .keyUp) {
        if type == .keyDown {
            let reverse = event.flags.contains(.maskShift)
            DispatchQueue.main.async { monitor.moveSearchSelection(reverse: reverse) }
        }
        return nil
    }

    if monitor.isSearchActiveForEventTap,
       (type == .keyDown || type == .keyUp) {
        if type == .keyDown {
            let text = keyboardText(from: event)
            DispatchQueue.main.async {
                monitor.handleSearchInput(keyCode: keyCode, text: text)
            }
        }
        return nil
    }

    if type == .keyUp, keyCode == tabKeyCode, commandPressed {
        return nil
    }

    if type == .flagsChanged, !commandPressed {
        // FIFO delivery: decide after preceding search/navigation events.
        DispatchQueue.main.async {
            if monitor.isSearchActiveForEventTap, monitor.keepSearchOpenForEventTap {
                monitor.detachSearchFromCommand()
            } else { monitor.finishCycle() }
        }
    }

    return Unmanaged.passUnretained(event)
}

@MainActor
final class GlobalShortcutMonitor: ObservableObject {
    @Published private(set) var state: ShortcutMonitorState = .disabled {
        didSet {
            if state != oldValue {
                logger.info("Estado do atalho: \(self.state.title, privacy: .public)")
            }
        }
    }

    private let windowManager: WindowManager
    private let settings: SettingsStore
    private let panelController: SwitcherPanelController
    private var eventTap: CFMachPort?
    private var eventTapLocation: CGEventTapLocation?
    private var runLoopSource: CFRunLoopSource?
    private var allCycleWindows: [WindowInfo] = []
    private var cycleWindows: [WindowInfo] = []
    private var selectedIndex = 0
    private var isCycling = false
    private var searchQuery = ""
    private var lastSearchShiftPress: TimeInterval?
    private var commandReleaseWatchdog: DispatchWorkItem?
    nonisolated(unsafe) fileprivate private(set) var isCycleActiveForEventTap = false
    nonisolated(unsafe) fileprivate private(set) var isSearchActiveForEventTap = false
    nonisolated(unsafe) fileprivate private(set) var isSearchDetachedForEventTap = false
    nonisolated(unsafe) fileprivate private(set) var searchShortcutForEventTap: SearchShortcut = .doubleShift
    nonisolated(unsafe) fileprivate private(set) var keepSearchOpenForEventTap = true
    private var retryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.taber.app", category: "shortcut")
    private let now: () -> TimeInterval
    private let activate: (WindowInfo) -> Void
    private let additionalWindows: () -> [WindowInfo]
    private let activateLocally: (WindowInfo) -> Bool
    private let commandIsPressed: () -> Bool
    var onCycleWillStart: () -> Void = {}

    init(windowManager: WindowManager, settings: SettingsStore, panelController: SwitcherPanelController,
         initialState: ShortcutMonitorState = .disabled,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         commandIsPressed: @escaping () -> Bool = {
             CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
         },
         additionalWindows: @escaping () -> [WindowInfo] = { [] },
         activateLocally: @escaping (WindowInfo) -> Bool = { _ in false },
         activate: ((WindowInfo) -> Void)? = nil) {
        self.windowManager = windowManager
        self.settings = settings
        self.panelController = panelController
        self.state = initialState
        self.now = now
        self.commandIsPressed = commandIsPressed
        self.additionalWindows = additionalWindows
        self.activateLocally = activateLocally
        self.activate = activate ?? { windowManager.activate($0) }
        searchShortcutForEventTap = settings.searchShortcut
        keepSearchOpenForEventTap = settings.keepSearchOpen

        settings.$shortcutEnabled
            .dropFirst()
            .sink { [weak self] _ in self?.reconfigure() }
            .store(in: &cancellables)

        settings.$searchShortcut
            .sink { [weak self] shortcut in
                self?.searchShortcutForEventTap = shortcut
            }
            .store(in: &cancellables)

        settings.$keepSearchOpen
            .sink { [weak self] keepOpen in
                self?.keepSearchOpenForEventTap = keepOpen
            }
            .store(in: &cancellables)
    }

    func start() {
        guard settings.shortcutEnabled else {
            state = .disabled
            return
        }

        installEventTapIfPossible()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.installEventTapIfPossible() }
        }
    }

    func reconfigure() {
        if settings.shortcutEnabled {
            installEventTapIfPossible()
        } else {
            cancelCycle()
            tearDownEventTap()
            state = .disabled
        }
    }

    func refreshPermissions() {
        installEventTapIfPossible()
    }

    private func installEventTapIfPossible() {
        guard settings.shortcutEnabled else {
            state = .disabled
            return
        }

        if let eventTap, CFMachPortIsValid(eventTap) {
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if CGEvent.tapIsEnabled(tap: eventTap) {
                state = .active
                return
            }
        } else if eventTap != nil {
            tearDownEventTap()
        }

        guard AccessibilityService.isTrusted else {
            state = .needsAccessibility
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        let preferredLocations: [CGEventTapLocation] = [
            .cghidEventTap,
            .cgSessionEventTap
        ]

        let installation = preferredLocations.lazy.compactMap { location -> (CFMachPort, CGEventTapLocation)? in
            guard let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: taberEventTapCallback,
                userInfo: opaqueSelf
            ) else {
                self.logger.warning("Event tap no nível \(location.taberDescription, privacy: .public) indisponível")
                return nil
            }
            return (tap, location)
        }.first

        guard let (createdTap, location) = installation else {
            state = .failed
            logger.error("Falha ao criar o event tap apesar da autorização de Acessibilidade")
            return
        }

        eventTap = createdTap
        eventTapLocation = location
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
        state = .active
        logger.info("Command + Tab event tap ativo no nível \(location.taberDescription, privacy: .public)")
    }

    func reenableEventTap() {
        guard let eventTap else {
            installEventTapIfPossible()
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        state = .active
    }

    func handleEventTapDisabled() {
        // Um tap desabilitado pode consumir o Command-up. Limpe primeiro toda
        // a apresentação; reativar mantendo `isCycling` deixava o painel preso.
        cancelCycle()
        reenableEventTap()
    }

    func beginOrAdvanceCycle(reverse: Bool) {
        guard settings.shortcutEnabled, state == .active else { return }

        if !isCycling {
            onCycleWillStart()
            AccessibilityService.cancelPendingRestoration()
            windowManager.refresh(includeUtilityWindows: settings.includeUtilityWindows)
            let localWindows = additionalWindows()
            let current = localWindows.first(where: \.isAccessibilityFocused)
                ?? windowManager.frontmostWindow()
            allCycleWindows = orderedWindows(
                windowManager.windows + localWindows,
                startingAt: current
            )
            cycleWindows = allCycleWindows
            guard !cycleWindows.isEmpty else { return }

            searchQuery = ""
            lastSearchShiftPress = nil
            selectedIndex = reverse ? cycleWindows.count - 1 : (current != nil && cycleWindows.count > 1 ? 1 : 0)
            isCycling = true
            isCycleActiveForEventTap = true
            isSearchActiveForEventTap = false
            isSearchDetachedForEventTap = false
            logger.notice("Ciclo iniciado: janelas=\(self.cycleWindows.count)")
            panelController.show(
                windows: cycleWindows,
                selectedIndex: selectedIndex,
                style: settings.switcherStyle,
                theme: settings.appTheme,
                size: settings.switcherSize,
                transparencyEnabled: settings.transparencyEnabled,
                keepSearchOpen: settings.keepSearchOpen
            )
            scheduleCommandReleaseWatchdog()
        } else {
            moveSelection(by: reverse ? -1 : 1)
        }
    }

    func navigate(using keyCode: Int64) {
        guard isCycling, !cycleWindows.isEmpty else { return }

        let delta: Int?
        switch settings.switcherStyle.navigationAxis {
        case .horizontal:
            switch keyCode {
            case leftArrowKeyCode: delta = -1
            case rightArrowKeyCode: delta = 1
            default: delta = nil
            }
        case .vertical:
            switch keyCode {
            case upArrowKeyCode: delta = -1
            case downArrowKeyCode: delta = 1
            default: delta = nil
            }
        }

        guard let delta else { return }
        moveSelection(by: delta)
    }

    private func moveSelection(by delta: Int) {
        guard !cycleWindows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + cycleWindows.count) % cycleWindows.count
        panelController.update(selectedIndex: selectedIndex)
    }

    func moveSearchSelection(reverse: Bool) {
        guard isSearchActiveForEventTap else { return }
        moveSelection(by: reverse ? -1 : 1)
    }

    func handleSearchShiftPress() {
        guard isCycling,
              !isSearchActiveForEventTap,
              settings.searchShortcut == .doubleShift
        else { return }

        let now = now()
        if let previous = lastSearchShiftPress, now - previous <= 0.48 {
            lastSearchShiftPress = nil
            enterSearch()
        } else {
            lastSearchShiftPress = now
        }
    }

    func enterSearch() {
        guard isCycling, !isSearchActiveForEventTap else { return }
        isSearchActiveForEventTap = true
        isSearchDetachedForEventTap = false
        searchQuery = ""
        lastSearchShiftPress = nil
        panelController.beginSearch(
            windows: cycleWindows,
            selectedIndex: selectedIndex,
            style: settings.switcherStyle,
            size: settings.switcherSize
        )
    }

    func handleSearchInput(keyCode: Int64, text: String) {
        guard isCycling, isSearchActiveForEventTap else { return }

        switch keyCode {
        case returnKeyCode:
            finishCycle()
            return
        case deleteKeyCode:
            if !searchQuery.isEmpty {
                searchQuery.removeLast()
            }
        default:
            var accepted = ""
            for scalar in text.unicodeScalars where scalar.value >= 32 && scalar.value != 127 {
                accepted.unicodeScalars.append(scalar)
            }
            guard !accepted.isEmpty else { return }
            searchQuery.append(accepted)
        }

        applySearchQuery()
    }

    func handleEscape() {
        if isSearchDetachedForEventTap {
            cancelCycle()
        } else if isSearchActiveForEventTap {
            exitSearch()
        } else {
            cancelCycle()
        }
    }

    func detachSearchFromCommand() {
        guard isCycling,
              isSearchActiveForEventTap,
              settings.keepSearchOpen,
              !isSearchDetachedForEventTap
        else { return }
        isSearchDetachedForEventTap = true
        panelController.detachSearchFromCommand()
    }

    private func applySearchQuery() {
        let selectedWindowID = cycleWindows.indices.contains(selectedIndex)
            ? cycleWindows[selectedIndex].id
            : nil
        cycleWindows = WindowSearchService.results(in: allCycleWindows, query: searchQuery)

        if let selectedWindowID,
           let preservedIndex = cycleWindows.firstIndex(where: { $0.id == selectedWindowID }) {
            selectedIndex = preservedIndex
        } else {
            selectedIndex = 0
        }

        panelController.updateSearchResults(
            windows: cycleWindows,
            selectedIndex: selectedIndex,
            query: searchQuery
        )
    }

    private func exitSearch() {
        let selectedWindowID = cycleWindows.indices.contains(selectedIndex)
            ? cycleWindows[selectedIndex].id
            : nil
        cycleWindows = allCycleWindows
        if let selectedWindowID,
           let restoredIndex = cycleWindows.firstIndex(where: { $0.id == selectedWindowID }) {
            selectedIndex = restoredIndex
        } else {
            selectedIndex = min(selectedIndex, max(cycleWindows.count - 1, 0))
        }
        searchQuery = ""
        isSearchActiveForEventTap = false
        isSearchDetachedForEventTap = false
        panelController.endSearch(
            windows: cycleWindows,
            selectedIndex: selectedIndex,
            style: settings.switcherStyle,
            size: settings.switcherSize
        )
    }

    func cancelCycle() {
        commandReleaseWatchdog?.cancel()
        commandReleaseWatchdog = nil
        guard isCycling else {
            panelController.hideDemo()
            return
        }
        isCycling = false
        isCycleActiveForEventTap = false
        isSearchActiveForEventTap = false
        isSearchDetachedForEventTap = false
        allCycleWindows = []
        cycleWindows = []
        searchQuery = ""
        lastSearchShiftPress = nil
        panelController.hide()
    }

    private func orderedWindows(_ ordered: [WindowInfo], startingAt current: WindowInfo?) -> [WindowInfo] {
        guard let currentID = current?.id,
              let currentIndex = ordered.firstIndex(where: { $0.id == currentID }) else {
            return ordered
        }
        return Array(ordered[currentIndex...]) + Array(ordered[..<currentIndex])
    }

    func finishCycle() {
        guard isCycling else { return }
        commandReleaseWatchdog?.cancel()
        commandReleaseWatchdog = nil
        isCycling = false
        isCycleActiveForEventTap = false
        isSearchActiveForEventTap = false
        isSearchDetachedForEventTap = false
        panelController.hide()

        guard cycleWindows.indices.contains(selectedIndex) else {
            allCycleWindows = []
            cycleWindows = []
            searchQuery = ""
            lastSearchShiftPress = nil
            return
        }

        let selectedWindow = cycleWindows[selectedIndex]
        logger.notice(
            "Ciclo concluído: alvo=\(selectedWindow.bundleIdentifier, privacy: .public) id=\(selectedWindow.id)"
        )
        allCycleWindows = []
        cycleWindows = []
        searchQuery = ""
        lastSearchShiftPress = nil
        if !activateLocally(selectedWindow) {
            activate(selectedWindow)
        }
    }

    private func scheduleCommandReleaseWatchdog() {
        commandReleaseWatchdog?.cancel()
        guard isCycling, !isSearchDetachedForEventTap else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isCycling, !self.isSearchDetachedForEventTap else { return }
            if self.commandIsPressed() {
                self.scheduleCommandReleaseWatchdog()
            } else if self.isSearchActiveForEventTap, self.settings.keepSearchOpen {
                self.detachSearchFromCommand()
            } else {
                self.finishCycle()
            }
        }
        commandReleaseWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func tearDownEventTap() {
        commandReleaseWatchdog?.cancel()
        commandReleaseWatchdog = nil
        isCycleActiveForEventTap = false
        isSearchActiveForEventTap = false
        isSearchDetachedForEventTap = false
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        eventTapLocation = nil
    }
}
