import AppKit
import Combine
import CoreGraphics
import os

private let tabKeyCode: Int64 = 48
private let returnKeyCode: Int64 = 36
private let deleteKeyCode: Int64 = 51
private let escapeKeyCode: Int64 = 53
private let qKeyCode: Int64 = 12
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

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if keyCode == qKeyCode, monitor.isQuitKeyHeldForEventTap {
        if type == .keyUp { monitor.isQuitKeyHeldForEventTap = false }
        return nil
    }

    if (type == .leftMouseDown || type == .rightMouseDown),
       monitor.isSearchDetachedForEventTap {
        DispatchQueue.main.async { monitor.cancelCycle() }
        return Unmanaged.passUnretained(event)
    }

    if type == .leftMouseDown || type == .rightMouseDown || (type == .keyDown && !monitor.isCycleActiveForEventTap) {
        DispatchQueue.main.async { monitor.cancelPendingActivation() }
    }
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

    if type == .keyDown,
       commandPressed,
       keyCode == qKeyCode,
       monitor.isCycleActiveForEventTap {
        monitor.isQuitKeyHeldForEventTap = true
        DispatchQueue.main.async { monitor.quitSelectedApplication() }
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
            monitor.handleCommandRelease()
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

    private let history: WindowRecencyHistory
    private var waitingForSnapshot = false
    private var pendingCommands: [PendingCycleCommand] = []
    private var commitWhenReady = false
    private var replayingColdCommands = false
    private var cycleGeneration: UInt = 0
    private var cycleStartedAt: TimeInterval = 0
    private enum PendingCycleCommand {
        case advance(Bool), navigate(Int64), search, searchInput(Int64, String)
        case moveSearch(Bool), exitSearch, detachSearch
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
    nonisolated(unsafe) fileprivate var isQuitKeyHeldForEventTap = false
    private var retryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.taber.app", category: "shortcut")
    private let now: () -> TimeInterval
    private let activate: (WindowInfo) -> Void
    private let terminateApplication: (WindowInfo) -> Bool
    fileprivate let cancelPendingActivation: () -> Void
    private let additionalWindows: () -> [WindowInfo]
    private let activateLocally: (WindowInfo) -> Bool
    private let commandIsPressed: () -> Bool
    var onCycleWillStart: () -> Void = {}

    init(windowManager: WindowManager, settings: SettingsStore, panelController: SwitcherPanelController,
         history: WindowRecencyHistory = WindowRecencyHistory(),
         initialState: ShortcutMonitorState = .disabled,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         commandIsPressed: @escaping () -> Bool = {
             CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
         },
         additionalWindows: @escaping () -> [WindowInfo] = { [] },
         activateLocally: @escaping (WindowInfo) -> Bool = { _ in false },
         cancelPendingActivation: @escaping () -> Void = { AccessibilityService.cancelPendingRestoration() },
         terminateApplication: @escaping (WindowInfo) -> Bool = { window in
             guard let application = NSRunningApplication(processIdentifier: window.activationPID),
                   !application.isTerminated,
                   WindowMatchingPolicy.canTerminateApplication(
                       expectedPID: window.activationPID,
                       expectedBundleIdentifier: window.bundleIdentifier,
                       expectedLaunchDate: window.activationProcessLaunchDate,
                       actualPID: application.processIdentifier,
                       actualBundleIdentifier: application.bundleIdentifier,
                       actualLaunchDate: application.launchDate
                   ) else { return false }
             return application.terminate()
         },
         activate: ((WindowInfo) -> Void)? = nil) {
        self.cancelPendingActivation = cancelPendingActivation
        self.history = history
        self.windowManager = windowManager
        self.settings = settings
        self.panelController = panelController
        self.state = initialState
        self.now = now
        self.commandIsPressed = commandIsPressed
        self.additionalWindows = additionalWindows
        self.activateLocally = activateLocally
        self.terminateApplication = terminateApplication
        self.activate = activate ?? { windowManager.activate($0) }
        windowManager.onSnapshot = { [weak self] windows in self?.receiveSnapshot(windows) }
        searchShortcutForEventTap = settings.searchShortcut
        keepSearchOpenForEventTap = settings.keepSearchOpen

        settings.$transparencyEnabled.combineLatest(settings.$transparencyPercent)
            .sink { [weak panelController] enabled, percent in
                panelController?.model.updateTransparency(enabled: enabled, percent: percent)
            }
            .store(in: &cancellables)

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

        if waitingForSnapshot {
            guard !commitWhenReady else { return }
            if pendingCommands.count < 256 { pendingCommands.append(.advance(reverse)) }
            return
        }
        if !isCycling {
            if !replayingColdCommands {
                cycleStartedAt = now()
                onCycleWillStart()
                cancelPendingActivation()
                if !windowManager.hasSnapshot { windowManager.refresh(includeUtilityWindows: settings.includeUtilityWindows) }
            }
            if !windowManager.hasSnapshot {
                waitingForSnapshot = true
                isCycleActiveForEventTap = true
                pendingCommands = [.advance(reverse)]
                commitWhenReady = false
                let generation = cycleGeneration
                windowManager.requestRefresh(includeUtilityWindows: settings.includeUtilityWindows) { [weak self] in
                    guard let self, self.waitingForSnapshot, self.cycleGeneration == generation else { return }
                    let commands = self.pendingCommands
                    let commit = self.commitWhenReady
                    self.waitingForSnapshot = false; self.pendingCommands = []; self.commitWhenReady = false
                    self.replayingColdCommands = true
                    defer { self.replayingColdCommands = false }
                    for command in commands {
                        switch command {
                        case let .advance(reverse): self.beginOrAdvanceCycle(reverse: reverse)
                        case let .navigate(key): self.navigate(using: key)
                        case .search: self.enterSearch()
                        case let .searchInput(key, text): self.handleSearchInput(keyCode: key, text: text)
                        case let .moveSearch(reverse): self.moveSearchSelection(reverse: reverse)
                        case .exitSearch: self.exitSearch()
                        case .detachSearch: self.detachSearchFromCommand()
                        }
                    }
                    if commit { self.finishCycle() }
                    if !self.isCycling {
                        // finishCycle may have just started a pending activation.
                        // Clearing the overlay must not cancel that transaction.
                        self.isCycleActiveForEventTap = false
                        self.isSearchActiveForEventTap = false
                        self.isSearchDetachedForEventTap = false
                    }
                }
                scheduleCommandReleaseWatchdog()
                return
            }
            let localWindows = additionalWindows()
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            let current = localWindows.first(where: \.isAccessibilityFocused)
                ?? history.current(in: windowManager.windows,
                    frontmostPID: frontmostApplication?.processIdentifier,
                    launchDate: frontmostApplication?.launchDate)
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
                transparencyPercent: settings.transparencyPercent,
                keepSearchOpen: settings.keepSearchOpen
            )
            TaberDiagnostics.record("panelOpened", fields: ["elapsedMs": (now() - cycleStartedAt) * 1000,
                "count": cycleWindows.count, "snapshotReady": !replayingColdCommands,
                "snapshotSource": replayingColdCommands ? "cold" : "warm"])
            DispatchQueue.main.async { [weak self] in
                guard let self, self.settings.shortcutEnabled else { return }
                self.windowManager.requestRefresh(includeUtilityWindows: self.settings.includeUtilityWindows)
            }
            scheduleCommandReleaseWatchdog()
        } else {
            moveSelection(by: reverse ? -1 : 1)
        }
    }

    func navigate(using keyCode: Int64) {
        if waitingForSnapshot {
            guard !commitWhenReady else { return }
            if pendingCommands.count < 256 { pendingCommands.append(.navigate(keyCode)) }
            return
        }
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
        if waitingForSnapshot {
            guard !commitWhenReady else { return }
            if pendingCommands.count < 256 { pendingCommands.append(.moveSearch(reverse)) }
            return
        }
        moveSelection(by: reverse ? -1 : 1)
    }

    func handleSearchShiftPress() {
        guard isCycling || waitingForSnapshot,
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
        if waitingForSnapshot {
            guard !commitWhenReady, !isSearchActiveForEventTap, pendingCommands.count < 256 else { return }
            pendingCommands.append(.search)
            isSearchActiveForEventTap = true
            isSearchDetachedForEventTap = false
            lastSearchShiftPress = nil
            return
        }
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
        guard (isCycling || waitingForSnapshot), isSearchActiveForEventTap else { return }
        if waitingForSnapshot {
            guard !commitWhenReady else { return }
            if keyCode == returnKeyCode { finishCycle(); return }
            if pendingCommands.count < 256 { pendingCommands.append(.searchInput(keyCode, text)) }
            return
        }

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
        if waitingForSnapshot && commitWhenReady {
            cancelCycle()
        } else if isSearchDetachedForEventTap {
            cancelCycle()
        } else if isSearchActiveForEventTap {
            exitSearch()
        } else {
            cancelCycle()
        }
    }

    func detachSearchFromCommand() {
        guard isCycling || waitingForSnapshot,
              isSearchActiveForEventTap,
              settings.keepSearchOpen,
              !isSearchDetachedForEventTap
        else { return }
        if waitingForSnapshot {
            guard !commitWhenReady, pendingCommands.count < 256 else { return }
            pendingCommands.append(.detachSearch)
            isSearchDetachedForEventTap = true
            return
        }
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
        if waitingForSnapshot {
            guard !commitWhenReady, pendingCommands.count < 256 else { return }
            pendingCommands.append(.exitSearch)
            isSearchActiveForEventTap = false
            isSearchDetachedForEventTap = false
            return
        }
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
        cycleGeneration &+= 1
        waitingForSnapshot = false; pendingCommands = []; commitWhenReady = false
        isCycleActiveForEventTap = false
        isSearchActiveForEventTap = false
        isSearchDetachedForEventTap = false
        lastSearchShiftPress = nil
        cancelPendingActivation()
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
        history.ordered(ordered, current: current)
    }

    private func receiveSnapshot(_ windows: [WindowInfo]) {
        guard isCycling, !waitingForSnapshot else { return }
        let latest = windows + additionalWindows()
        let live = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = cycleWindows.indices.contains(selectedIndex) ? cycleWindows[selectedIndex].id : nil
        if let selected, live[selected] == nil { cancelCycle(); return }
        let existingIDs = Set(allCycleWindows.map(\.id))
        allCycleWindows = allCycleWindows.compactMap { live[$0.id] } + latest.filter { !existingIDs.contains($0.id) }
        if panelController.model.isSearching {
            applySearchQuery()
        } else {
            cycleWindows = allCycleWindows
            selectedIndex = selected.flatMap { id in cycleWindows.firstIndex { $0.id == id } } ?? 0
            panelController.updateWindowList(windows: cycleWindows, selectedIndex: selectedIndex)
        }
    }

    func handleCommandRelease() {
        if isSearchActiveForEventTap, settings.keepSearchOpen {
            detachSearchFromCommand()
        } else {
            finishCycle()
        }
    }

    func finishCycle() {
        if waitingForSnapshot { commitWhenReady = true; return }
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

    /// Command-Q applies to the selected destination while the switcher owns
    /// the shortcut. It never activates that destination first.
    func quitSelectedApplication() {
        guard isCycling || waitingForSnapshot else { return }
        // There is no stable selected target during a cold collection. Treat
        // Command-Q as a cancellation so Command release cannot activate one.
        guard cycleWindows.indices.contains(selectedIndex) else {
            cancelCycle()
            return
        }
        let selectedWindow = cycleWindows[selectedIndex]
        cycleGeneration &+= 1
        waitingForSnapshot = false
        pendingCommands = []
        commitWhenReady = false
        commandReleaseWatchdog?.cancel()
        commandReleaseWatchdog = nil
        isCycling = false
        isCycleActiveForEventTap = false
        isSearchActiveForEventTap = false
        isSearchDetachedForEventTap = false
        allCycleWindows = []
        cycleWindows = []
        searchQuery = ""
        lastSearchShiftPress = nil
        cancelPendingActivation()
        panelController.hide()
        let terminated = terminateApplication(selectedWindow)
        TaberDiagnostics.record("selectedApplicationQuit", fields: [
            "target": TaberDiagnostics.identity(selectedWindow),
            "activationPID": selectedWindow.activationPID,
            "sent": terminated
        ])
        logger.notice("Encerramento solicitado: pid=\(selectedWindow.activationPID) enviado=\(terminated)")
    }

    private func scheduleCommandReleaseWatchdog() {
        commandReleaseWatchdog?.cancel()
        guard (isCycling || waitingForSnapshot), !isSearchDetachedForEventTap else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, (self.isCycling || self.waitingForSnapshot), !self.isSearchDetachedForEventTap else { return }
            if self.commandIsPressed() {
                self.scheduleCommandReleaseWatchdog()
            } else {
                self.handleCommandRelease()
            }
        }
        commandReleaseWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func tearDownEventTap() {
        commandReleaseWatchdog?.cancel()
        commandReleaseWatchdog = nil
        isQuitKeyHeldForEventTap = false
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
