import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import os

struct AccessibilityWindowSnapshot: Sendable {
    let windowID: CGWindowID?
    let identifier: String
    let title: String
    let document: String
    let subrole: String
    let bounds: CGRect
    let isMinimized: Bool
    let isMain: Bool
    let isFocused: Bool
    let ordinal: Int
    var role: String = ""
    var isNativeFullScreen = false

    var identityFallback: AccessibilityWindowFallback {
        AccessibilityWindowFallback(document: document, title: title, bounds: bounds, ordinal: ordinal)
    }
}

private final class AccessibilitySnapshotAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [pid_t: [AccessibilityWindowSnapshot]] = [:]
    private var completeness: [pid_t: Bool] = [:]

    func store(_ snapshots: [AccessibilityWindowSnapshot], for pid: pid_t, complete: Bool) {
        lock.lock()
        storage[pid] = snapshots
        completeness[pid] = complete
        lock.unlock()
    }

    func snapshot() -> (values: [pid_t: [AccessibilityWindowSnapshot]], completeness: [pid_t: Bool]) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, completeness)
    }
}

/// Injectable snapshots keep WindowServer/AX integration out of deterministic tests.
@MainActor
protocol WindowSnapshotSource {
    var frontmostPID: pid_t? { get }
    func candidates(includeUtilityWindows: Bool) -> [WindowInfo]
    func accessibilityWindows(for pid: pid_t, includeUtilityWindows: Bool) -> [AccessibilityWindowSnapshot]
    func accessibilitySnapshotIsComplete(for pid: pid_t) -> Bool
    func spaces(for ids: [CGWindowID]) -> [CGWindowID: ResolvedWindowSpace]
}

extension WindowSnapshotSource {
    func accessibilitySnapshotIsComplete(for pid: pid_t) -> Bool { true }
}

private struct CapturedScreen: Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
    let localizedName: String
    @MainActor static func capture() -> [Self] {
        NSScreen.screens.map { Self(frame: $0.frame, visibleFrame: $0.visibleFrame, localizedName: $0.localizedName) }
    }
}

// NSImage is captured on main and only passed through by the worker; it is
// never drawn into or mutated outside the main actor.
private struct CapturedApplication: @unchecked Sendable {
    let processIdentifier: pid_t
    let localizedName: String?
    let bundleIdentifier: String?
    let bundleURL: URL?
    let launchDate: Date?
    let activationPolicy: NSApplication.ActivationPolicy
    let icon: NSImage?
    let isTerminated: Bool
    @MainActor init(_ app: NSRunningApplication, icon: NSImage?) {
        processIdentifier = app.processIdentifier; localizedName = app.localizedName
        bundleIdentifier = app.bundleIdentifier; bundleURL = app.bundleURL
        launchDate = app.launchDate; activationPolicy = app.activationPolicy
        self.icon = icon; isTerminated = app.isTerminated
    }
}

private struct CapturedDesktop: Sendable {
    let screens: [CapturedScreen]
    let applications: [pid_t: CapturedApplication]
    let frontmostPID: pid_t?
    @MainActor static func capture(previousApplications: [pid_t: CapturedApplication]) -> Self {
        let workspace = NSWorkspace.shared
        let applications = workspace.runningApplications.filter { $0.localizedName != nil }.map { app in
            let old = previousApplications[app.processIdentifier]
            let icon = old != nil && old?.launchDate == app.launchDate ? old?.icon : app.icon
            return (app.processIdentifier, CapturedApplication(app, icon: icon))
        }
        return Self(screens: CapturedScreen.capture(),
                    applications: Dictionary(uniqueKeysWithValues: applications),
                    frontmostPID: workspace.frontmostApplication?.processIdentifier)
    }
}

@MainActor
final class WindowManager {
    typealias SnapshotScheduler = (@escaping @MainActor () -> Void) -> Void
    private let source: (any WindowSnapshotSource)?
    private let snapshotScheduler: SnapshotScheduler?
    private let worker = WindowSnapshotWorker()
    private let queue = DispatchQueue(label: "com.taber.window-snapshots", qos: .userInitiated)
    private(set) var windows: [WindowInfo] = []
    private(set) var hasSnapshot = false
    var onSnapshot: (([WindowInfo]) -> Void)?
    var onTrackingSnapshot: (([WindowInfo]) -> Void)?
    private var capturedApplications: [pid_t: CapturedApplication] = [:]
    private var inFlight = false
    private var suspended = false
    private var generation = 0
    private var pendingRefresh = false
    private var requestedUtilityWindows = false
    private var completion: (() -> Void)?

    init(source: (any WindowSnapshotSource)? = nil, snapshotScheduler: SnapshotScheduler? = nil) {
        self.source = source
        self.snapshotScheduler = snapshotScheduler
    }

    /// The synchronous path exists only for injected, deterministic fixtures.
    func refresh(includeUtilityWindows: Bool = false) {
        guard let source, snapshotScheduler == nil else {
            requestRefresh(includeUtilityWindows: includeUtilityWindows); return
        }
        windows = injectedSnapshot(source: source, includeUtilityWindows: includeUtilityWindows)
        hasSnapshot = true
        onTrackingSnapshot?(windows)
        onSnapshot?(windows)
    }

    private func injectedSnapshot(source: any WindowSnapshotSource, includeUtilityWindows: Bool) -> [WindowInfo] {
        let candidates = source.candidates(includeUtilityWindows: includeUtilityWindows)
        let pids = Set(candidates.map(\.ownerPID))
        let snapshots = Dictionary(uniqueKeysWithValues: pids.map {
            ($0, source.accessibilityWindows(for: $0, includeUtilityWindows: includeUtilityWindows))
        })
        let completeness = Dictionary(uniqueKeysWithValues: pids.map { ($0, source.accessibilitySnapshotIsComplete(for: $0)) })
        let ids = Set(candidates.compactMap(\.windowServerID) + snapshots.values.flatMap { $0.compactMap(\.windowID) })
        return worker.reconcileInjected(candidates, frontmostPID: source.frontmostPID,
            includeUtilityWindows: includeUtilityWindows, snapshots: snapshots, completeness: completeness,
            spaces: source.spaces(for: Array(ids)), screens: CapturedScreen.capture())
    }

    /// Coalesces repeated requests into one pending scan. A newer completion
    /// replaces the older waiter, avoiding an unbounded callback queue.
    func requestRefresh(includeUtilityWindows: Bool = false, completion: (() -> Void)? = nil) {
        guard !suspended else { return }
        if source != nil && snapshotScheduler == nil {
            refresh(includeUtilityWindows: includeUtilityWindows); completion?(); return
        }
        requestedUtilityWindows = includeUtilityWindows
        if let completion { self.completion = completion }
        guard !inFlight else { pendingRefresh = true; return }
        beginRefresh()
    }

    private func beginRefresh() {
        inFlight = true
        pendingRefresh = false
        let includeUtilityWindows = requestedUtilityWindows
        let scanGeneration = generation
        if let source, let snapshotScheduler {
            // Hold publication in deterministic tests, while exercising the
            // same coalescing, generation and callback path as live scans.
            let result = injectedSnapshot(source: source, includeUtilityWindows: includeUtilityWindows)
            snapshotScheduler { [weak self] in
                self?.finishRefresh(result, includeUtilityWindows: includeUtilityWindows, generation: scanGeneration)
            }
            return
        }
        let context = CapturedDesktop.capture(previousApplications: capturedApplications)
        capturedApplications = context.applications
        let worker = worker
        queue.async { [weak self] in
            let result = worker.refresh(context: context, includeUtilityWindows: includeUtilityWindows)
            Task { @MainActor [weak self] in
                self?.finishRefresh(result, includeUtilityWindows: includeUtilityWindows, generation: scanGeneration)
            }
        }
    }

    private func finishRefresh(_ result: [WindowInfo], includeUtilityWindows: Bool, generation scanGeneration: Int) {
        inFlight = false
        guard scanGeneration == generation, !suspended else {
            if !suspended && pendingRefresh { beginRefresh() }
            return
        }
        guard includeUtilityWindows == requestedUtilityWindows else {
            beginRefresh()
            return
        }
        windows = result
        hasSnapshot = true
        let completion = self.completion
        self.completion = nil
        onTrackingSnapshot?(result)
        onSnapshot?(result)
        if scanGeneration == generation, !suspended { completion?() }
        if pendingRefresh && !inFlight && !suspended { beginRefresh() }
    }

    func suspend() {
        suspended = true
        generation += 1
        pendingRefresh = false
        completion = nil
    }

    func resume() {
        suspended = false
        requestRefresh(includeUtilityWindows: requestedUtilityWindows)
    }

    func windows(forApplicationID applicationID: String) -> [WindowInfo] {
        windows.filter { $0.applicationIdentifier == applicationID }
    }

    func frontmostWindow() -> WindowInfo? {
        let pid = source.map { $0.frontmostPID } ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = windows.map {
            (ownerPID: $0.activationPID == pid ? $0.activationPID : $0.ownerPID,
             isMinimized: $0.isMinimized, isFocused: $0.isAccessibilityFocused)
        }
        guard let index = WindowMatchingPolicy.preferredFrontmostIndex(frontmostPID: pid, candidates: candidates) else { return nil }
        return windows[index]
    }

    func activate(_ window: WindowInfo) { AccessibilityService.restoreAndRaise(window: window) }
}

private final class WindowSnapshotWorker: @unchecked Sendable {
    private(set) var windows: [WindowInfo] = []
    private var exactMatchesInRefresh = 0
    private var didReportIdentityResolver = false
    private var refreshDeadline = TimeInterval.greatestFiniteMagnitude
    private var snapshotComplete = true
    private var accessibilitySnapshotCache: [pid_t: [AccessibilityWindowSnapshot]] = [:]
    private var accessibilitySnapshotCompleteness: [pid_t: Bool] = [:]
    private var screens: [CapturedScreen] = []
    private var injectedSpaces: [CGWindowID: ResolvedWindowSpace]?
    private var lastConfirmedAt: [WindowIdentity: TimeInterval] = [:]
    private let logger = Logger(subsystem: "com.taber.app", category: "windows")

    func refresh(context: CapturedDesktop, includeUtilityWindows: Bool) -> [WindowInfo] {
        screens = context.screens
        refreshDeadline = ProcessInfo.processInfo.systemUptime + 0.32
        injectedSpaces = nil
        let refreshStartedAt = ContinuousClock.now
        exactMatchesInRefresh = 0
        accessibilitySnapshotCache.removeAll(keepingCapacity: true)
        accessibilitySnapshotCompleteness.removeAll(keepingCapacity: true)
        if !didReportIdentityResolver {
            logger.notice(
                "Identidade AX-WindowServer disponível=\(AccessibilityWindowIdentityResolver.isAvailable)"
            )
            didReportIdentityResolver = true
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = context.frontmostPID
        let runningApplications = context.applications
        var activationApplicationCache: [pid_t: CapturedApplication] = [:]

        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            // WindowServer failure is not evidence that every window closed.
            return windows
        }

        var activePIDs = Set<pid_t>()
        var rawCandidates: [WindowInfo] = windowList.compactMap { info in
            guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            let ownerPID = ownerPIDNumber.int32Value
            guard ownerPID != ownPID,
                  let application = runningApplications[ownerPID],
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return nil }

            let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            guard windowID != 0 else { return nil }

            let title = info[kCGWindowName as String] as? String ?? ""
            let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let ownerBundleIdentifier = application.bundleIdentifier ?? ""
            let bundlePath = application.bundleURL?.path ?? ""
            let activationApplication: CapturedApplication
            if let cached = activationApplicationCache[ownerPID] {
                activationApplication = cached
            } else {
                activationApplication = responsibleActivationApplication(
                    for: application,
                    among: runningApplications
                )
                activationApplicationCache[ownerPID] = activationApplication
            }
            let bundleIdentifier = activationApplication.bundleIdentifier ?? ownerBundleIdentifier
            let eligibility = WindowEligibilityContext(
                bundleIdentifier: ownerBundleIdentifier,
                activationPolicy: application.activationPolicy,
                title: title,
                bounds: bounds,
                layer: layer.intValue,
                alpha: alpha,
                isOnScreen: isOnScreen,
                isHelperProcess: bundlePath.contains(".app/Contents/") || bundlePath.hasSuffix(".xpc")
            )
            guard WindowEligibilityPolicy.allows(
                eligibility,
                includeUtilityWindows: includeUtilityWindows
            ) else { return nil }

            activePIDs.insert(ownerPID)
            let icon = application.icon

            return WindowInfo(
                id: windowID,
                ownerPID: ownerPID,
                bundleIdentifier: bundleIdentifier,
                applicationName: activationApplication.localizedName ?? application.localizedName ?? "Aplicativo",
                title: title,
                bounds: bounds,
                isOnScreen: isOnScreen,
                // Fora da tela também pode significar outro Space. O estado
                // minimizado verdadeiro será reconciliado via Acessibilidade.
                isMinimized: false,
                isFullScreen: false,
                screenName: screenName(for: bounds),
                icon: activationApplication.icon ?? icon,
                processLaunchDate: application.launchDate,
                activationPID: activationApplication.processIdentifier,
                activationProcessLaunchDate: activationApplication.launchDate
            )
        }

        // Accessibility is an independent source, rather than enrichment that
        // only runs after WindowServer returned a surface. This recovers fully
        // minimized/AX-only windows and standard dialogs omitted by CG.
        let knownWindowIDsByPID = Dictionary(grouping: rawCandidates, by: \.ownerPID)
            .mapValues { Set($0.compactMap(\.windowServerID)) }
        let orderedApplications = runningApplications.values.filter { app in
            guard app.processIdentifier != ownPID, !app.isTerminated else { return false }
            if activePIDs.contains(app.processIdentifier) { return true }
            if app.activationPolicy == .regular { return true }
            return includeUtilityWindows && app.activationPolicy == .accessory
        }.sorted { lhs, rhs in
            if lhs.processIdentifier == frontmostPID { return true }
            if rhs.processIdentifier == frontmostPID { return false }
            let lhsHasCG = activePIDs.contains(lhs.processIdentifier)
            let rhsHasCG = activePIDs.contains(rhs.processIdentifier)
            if lhsHasCG != rhsHasCG { return lhsHasCG }
            return lhs.processIdentifier < rhs.processIdentifier
        }
        let concurrentSnapshotResult = collectAccessibilitySnapshots(
            for: orderedApplications,
            knownWindowIDsByPID: knownWindowIDsByPID,
            includeUtilityWindows: includeUtilityWindows
        )
        let concurrentSnapshots = concurrentSnapshotResult.snapshots
        accessibilitySnapshotCache = concurrentSnapshots
        accessibilitySnapshotCompleteness = concurrentSnapshotResult.completeness
        for application in orderedApplications where application.processIdentifier != ownPID {
            let pid = application.processIdentifier
            let snapshots = concurrentSnapshots[pid] ?? []
            guard !snapshots.isEmpty else { continue }
            let existingWindowIDs = Set(rawCandidates.filter { $0.ownerPID == pid }.compactMap(\.windowServerID))
            for snapshot in snapshots where snapshot.windowID == nil || !existingWindowIDs.contains(snapshot.windowID!) {
                let activationApplication: CapturedApplication
                if let cached = activationApplicationCache[pid] {
                    activationApplication = cached
                } else {
                    activationApplication = responsibleActivationApplication(
                        for: application,
                        among: runningApplications
                    )
                    activationApplicationCache[pid] = activationApplication
                }
                guard WindowEligibilityPolicy.isUserAccessibilitySurface(
                    bundleIdentifier: application.bundleIdentifier ?? "", role: snapshot.role,
                    subrole: snapshot.subrole) else { continue }
                let context = WindowEligibilityContext(
                    bundleIdentifier: application.bundleIdentifier ?? "",
                    activationPolicy: application.activationPolicy,
                    title: snapshot.title,
                    bounds: snapshot.bounds,
                    layer: 0,
                    alpha: 1,
                    isOnScreen: !snapshot.isMinimized,
                    isHelperProcess: (application.bundleURL?.path ?? "").contains(".app/Contents/"),
                    evidence: .accessibility,
                    accessibilitySubrole: snapshot.subrole
                )
                guard WindowEligibilityPolicy.allows(context, includeUtilityWindows: includeUtilityWindows) else { continue }
                let identity: WindowIdentity = snapshot.windowID.map {
                    .windowServer(ownerPID: pid, launchDate: application.launchDate, id: $0)
                } ?? .accessibility(ownerPID: pid, launchDate: application.launchDate,
                                    identifier: snapshot.identifier, fallback: snapshot.identityFallback)
                rawCandidates.append(WindowInfo(
                    identity: identity, windowServerID: snapshot.windowID, ownerPID: pid,
                    bundleIdentifier: activationApplication.bundleIdentifier ?? application.bundleIdentifier ?? "",
                    applicationName: activationApplication.localizedName ?? application.localizedName ?? "Aplicativo", title: snapshot.title,
                    bounds: snapshot.bounds, isOnScreen: !snapshot.isMinimized,
                    isMinimized: snapshot.isMinimized, isFullScreen: snapshot.isNativeFullScreen,
                    icon: application.icon, accessibilityIdentifier: snapshot.identifier,
                    accessibilityOrdinal: snapshot.ordinal, isAccessibilityFocused: snapshot.isFocused,
                    processLaunchDate: application.launchDate,
                    activationPID: activationApplication.processIdentifier,
                    activationProcessLaunchDate: activationApplication.launchDate
                ))
                activePIDs.insert(pid)
            }
        }

        let serverIDs = Set(windowList.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let axIDs = Set(concurrentSnapshots.values.flatMap { $0.compactMap(\.windowID) })
        let liveProcessDates: [pid_t: Date?] = Dictionary(
            uniqueKeysWithValues: runningApplications.map { ($0.key, $0.value.launchDate) }
        )
        AXWindowReferenceCache.shared.retain(liveWindows: serverIDs.union(axIDs),
            processes: liveProcessDates)
        let previousWindows = windows
        windows = reconcile(rawCandidates, frontmostPID: frontmostPID, includeUtilityWindows: includeUtilityWindows)
        let now = ProcessInfo.processInfo.systemUptime
        let emitted = Set(windows.map(\.id))
        for window in windows { lastConfirmedAt[window.id] = now }
        // An incomplete AX response must not erase a known window in another
        // Space. CG existence is positive evidence; AX-only windows get a
        // short grace period, so an unresponsive process cannot leave ghosts.
        for previous in previousWindows where !emitted.contains(previous.id) {
            guard let process = runningApplications[previous.ownerPID],
                  process.launchDate == previous.processLaunchDate,
                  accessibilitySnapshotCompleteness[previous.ownerPID] != true else { continue }
            let stillInServer = previous.windowServerID.map { serverIDs.contains($0) } ?? false
            let recentlyConfirmed = now - (lastConfirmedAt[previous.id] ?? 0) < 2
            if stillInServer || recentlyConfirmed { windows.append(previous) }
        }
        let retainedIDs = Set(windows.map(\.id))
        lastConfirmedAt = lastConfirmedAt.filter { retainedIDs.contains($0.key) }
        let elapsed = refreshStartedAt.duration(to: .now)
        logger.notice("Varredura: janelas=\(self.windows.count) duração=\(String(describing: elapsed), privacy: .public)")
        return windows
    }

    func reconcileInjected(_ candidates: [WindowInfo], frontmostPID: pid_t?, includeUtilityWindows: Bool,
                           snapshots: [pid_t: [AccessibilityWindowSnapshot]], completeness: [pid_t: Bool],
                           spaces: [CGWindowID: ResolvedWindowSpace], screens: [CapturedScreen]) -> [WindowInfo] {
        self.screens = screens
        accessibilitySnapshotCache = snapshots
        accessibilitySnapshotCompleteness = completeness
        injectedSpaces = spaces
        windows = reconcile(candidates, frontmostPID: frontmostPID, includeUtilityWindows: includeUtilityWindows)
        return windows
    }

    private func reconcile(_ rawCandidates: [WindowInfo], frontmostPID: pid_t?, includeUtilityWindows: Bool) -> [WindowInfo] {
        let candidatesByPID = Dictionary(grouping: rawCandidates, by: \.ownerPID)
        var canonicalWindowsByServerID: [CGWindowID: WindowInfo] = [:]
        var canonicalAccessibilityWindows: [WindowInfo] = []

        let orderedPIDs = candidatesByPID.keys.sorted {
            if $0 == frontmostPID { return true }
            if $1 == frontmostPID { return false }
            return $0 < $1
        }
        for ownerPID in orderedPIDs {
            guard let applicationCandidates = candidatesByPID[ownerPID] else { continue }
            let selected = canonicalWindows(
                from: applicationCandidates,
                ownerPID: ownerPID,
                includeUtilityWindows: includeUtilityWindows,
                isFrontmostApplication: applicationCandidates.contains { $0.ownerPID == frontmostPID || $0.activationPID == frontmostPID }
            )
            for window in selected {
                if let windowServerID = window.windowServerID {
                    canonicalWindowsByServerID[windowServerID] = window
                } else if !canonicalAccessibilityWindows.contains(where: { $0.id == window.id }) {
                    canonicalAccessibilityWindows.append(window)
                }
            }

            if selected.count < applicationCandidates.count {
                logger.notice(
                    "Superfícies duplicadas removidas: pid=\(ownerPID) candidatas=\(applicationCandidates.count) janelas=\(selected.count)"
                )
            }
        }

        // CGWindowListCopyWindowInfo já vem em ordem visual, da frente para
        // trás. Filtrar o array original preserva essa ordem depois da
        // reconciliação com as janelas reais da Acessibilidade.
        var emittedWindowServerIDs = Set<CGWindowID>()
        var canonicalWindows = rawCandidates.compactMap { candidate -> WindowInfo? in
            guard let windowServerID = candidate.windowServerID,
                  emittedWindowServerIDs.insert(windowServerID).inserted
            else { return nil }
            return canonicalWindowsByServerID[windowServerID]
        }
        let recoveredWindowServerWindows = canonicalWindowsByServerID
            .filter { !emittedWindowServerIDs.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map(\.value)
        canonicalWindows.append(contentsOf: recoveredWindowServerWindows)
        canonicalWindows.append(contentsOf: canonicalAccessibilityWindows.sorted { $0.id.description < $1.id.description })
        // Consultar o Space exige uma chamada ao WindowServer por janela.
        // Faça isso somente depois de remover superfícies auxiliares.
        let windowServerIDs = canonicalWindows.compactMap { $0.presentationWindowID ?? $0.windowServerID }
        let resolvedSpaces = injectedSpaces
            ?? SpaceResolver.shared.resolve(windowIDs: windowServerIDs)
        let resolvedWindows: [WindowInfo]
        if resolvedSpaces.isEmpty {
            resolvedWindows = canonicalWindows
        } else {
            resolvedWindows = canonicalWindows.map { window in
                window.withResolvedSpace((window.presentationWindowID ?? window.windowServerID).flatMap { resolvedSpaces[$0] })
            }
        }
        return disambiguateRepeatedTitles(in: resolvedWindows)
    }

    private func canonicalWindows(
        from candidates: [WindowInfo],
        ownerPID: pid_t,
        includeUtilityWindows: Bool,
        isFrontmostApplication: Bool
    ) -> [WindowInfo] {
        // O WindowServer pode levar alguns milissegundos para refletir um
        // Command + M. O aplicativo em primeiro plano precisa ser confirmado
        // via AX mesmo quando só possui uma superfície ainda marcada on-screen.
        let isFinder = candidates.first?.bundleIdentifier == "com.apple.finder"
        // Even singleton renderers need AX evidence to choose their activation strategy.
        let accessibilityWindows = accessibilityWindows(
            for: ownerPID,
            includeUtilityWindows: includeUtilityWindows
        ).filter {
            WindowEligibilityPolicy.isUserAccessibilitySurface(
                bundleIdentifier: candidates.first?.bundleIdentifier ?? "", role: $0.role, subrole: $0.subrole)
        }

        guard !accessibilityWindows.isEmpty else {
            // Finder exposes desktop/preview surfaces even with no document windows.
            // Only a complete AX response can prove its window list is empty.
            if isFinder && snapshotComplete { return [] }
            // Alguns processos regulares mantêm superfícies 500×500 vazias
            // no WindowServer mesmo sem possuir uma janela alternável. Sem
            // confirmação AX, preserve apenas superfícies com evidência real.
            let credibleCandidates = credibleFallbackCandidates(candidates)
            // IDs distintos são preservados mesmo com título/geometria iguais.
            // Sem AX, a ativação precisa validar o destino a partir da superfície CG.
            return consolidateAmbiguousApplicationSurfaces(credibleCandidates)
        }

        var isMatched = [Bool](repeating: false, count: candidates.count)
        var matched: [(window: WindowInfo, accessibility: AccessibilityWindowSnapshot)] = []
        var exactIndexByWindowID: [CGWindowID: Int] = [:]
        var duplicateWindowIDs = Set<CGWindowID>()
        for (index, candidate) in candidates.enumerated() {
            guard let windowID = candidate.windowServerID else { continue }
            if exactIndexByWindowID.updateValue(index, forKey: windowID) != nil {
                duplicateWindowIDs.insert(windowID)
            }
        }
        for duplicateWindowID in duplicateWindowIDs {
            exactIndexByWindowID.removeValue(forKey: duplicateWindowID)
        }

        for accessibilityWindow in accessibilityWindows {
            let bestIndex: Int?
            if let exactWindowID = accessibilityWindow.windowID,
               let exactIndex = exactIndexByWindowID[exactWindowID],
               !isMatched[exactIndex] {
                bestIndex = exactIndex
                exactMatchesInRefresh += 1
            } else if accessibilityWindow.windowID == nil {
                let scored = candidates.indices.compactMap { index -> (Int, Int)? in
                    guard !isMatched[index] else { return nil }
                    let candidate = candidates[index]
                    guard let score = matchScore(
                        candidate,
                        accessibilityWindow,
                        candidateVisualOrder: index
                    ) else { return nil }
                    return (index, score)
                }
                if let best = scored.max(by: { $0.1 < $1.1 }),
                   scored.filter({ $0.1 == best.1 }).count == 1 { bestIndex = best.0 }
                else { bestIndex = nil }
            } else {
                bestIndex = nil
            }
            guard let bestIndex else {
                // Minimized AX windows may temporarily disappear from CGWindowList.
                if let template = candidates.first {
                    let identity: WindowIdentity = accessibilityWindow.windowID.map {
                        .windowServer(ownerPID: ownerPID, launchDate: template.processLaunchDate, id: $0)
                    } ?? .accessibility(ownerPID: ownerPID, launchDate: template.processLaunchDate,
                                       identifier: accessibilityWindow.identifier,
                                       fallback: accessibilityWindow.identityFallback)
                    let recovered = WindowInfo(identity: identity, windowServerID: accessibilityWindow.windowID,
                        ownerPID: ownerPID, bundleIdentifier: template.bundleIdentifier,
                        applicationName: template.applicationName, title: accessibilityWindow.title,
                        bounds: accessibilityWindow.bounds, isOnScreen: false,
                        isMinimized: accessibilityWindow.isMinimized, icon: template.icon,
                        accessibilityIdentifier: accessibilityWindow.identifier,
                        accessibilityOrdinal: accessibilityWindow.ordinal,
                        isAccessibilityFocused: accessibilityWindow.isFocused,
                        processLaunchDate: template.processLaunchDate,
                        activationPID: template.activationPID,
                        activationProcessLaunchDate: template.activationProcessLaunchDate)
                    matched.append((recovered, accessibilityWindow))
                }
                continue
            }
            isMatched[bestIndex] = true
            let candidate = candidates[bestIndex]
            let candidateActivationMode = activationMode(
                for: candidate,
                accessibilityWindow: accessibilityWindow
            )
            if candidateActivationMode == .activateApplication {
                logger.notice(
                    "Fullscreen de conteúdo detectado: pid=\(ownerPID) janela=\(candidate.windowServerID ?? 0, privacy: .public)"
                )
            }
            matched.append((
                window: candidate.withAccessibilityIdentity(
                    identifier: accessibilityWindow.identifier,
                    ordinal: accessibilityWindow.ordinal,
                    accessibilityTitle: accessibilityWindow.title,
                    isMinimized: accessibilityWindow.isMinimized,
                    isFullScreen: candidate.isFullScreen
                        || accessibilityWindow.isNativeFullScreen
                        || candidateActivationMode == .activateApplication,
                    isFocused: accessibilityWindow.isFocused,
                    activationMode: candidateActivationMode
                ),
                accessibility: accessibilityWindow
            ))
        }
        let remaining = candidates.indices.compactMap { isMatched[$0] ? nil : candidates[$0] }
        let matchedAccessibilityWindowCount = matched.count

        // WebKit e Chromium podem expor o player fullscreen como AXDialog e
        // manter também a AXStandardWindow que hospeda a mesma aba. Para o
        // usuário isso é uma única janela: mantenha a superfície do player
        // (melhor miniatura) com a identidade/título da janela hospedeira.
        if candidates.first.map({ isBrowser($0.bundleIdentifier) }) == true {
            var hostIndicesToRemove = Set<Int>()
            let presentationIndices = matched.indices.filter { index in
                matched[index].accessibility.subrole == kAXDialogSubrole as String
                    && matched[index].window.activationMode == .activateApplication
            }

            for presentationIndex in presentationIndices {
                let presentation = matched[presentationIndex]
                let hostCandidates = matched.indices.compactMap { index -> (index: Int, ordinal: Int, document: String)? in
                    guard index != presentationIndex,
                          !hostIndicesToRemove.contains(index),
                          matched[index].accessibility.subrole != kAXDialogSubrole as String
                    else { return nil }
                    return (
                        index,
                        matched[index].accessibility.ordinal,
                        matched[index].accessibility.document
                    )
                }
                guard let hostIndex = WindowMatchingPolicy.preferredContentHostIndex(
                    presentationOrdinal: presentation.accessibility.ordinal,
                    presentationDocument: presentation.accessibility.document,
                    candidates: hostCandidates,
                    requireUniqueHost: true
                ) else { continue }

                let hostMatch = matched[hostIndex]
                let host = hostMatch.accessibility
                matched[hostIndex].window = hostMatch.window.withAccessibilityIdentity(
                    identifier: host.identifier,
                    ordinal: host.ordinal,
                    accessibilityTitle: host.title,
                    isMinimized: host.isMinimized,
                    isFullScreen: true,
                    isFocused: host.isFocused || presentation.accessibility.isFocused,
                    activationMode: .activateApplication
                ).withPresentation(
                    windowID: presentation.window.windowServerID,
                    isOnScreen: hostMatch.window.isOnScreen || presentation.window.isOnScreen
                ).withActivationMode(.raiseWindow)
                hostIndicesToRemove.insert(presentationIndex)
                logger.notice("Janela-base de fullscreen de conteúdo consolidada: pid=\(ownerPID)")
            }

            if !hostIndicesToRemove.isEmpty {
                let preservedMatches = matched.enumerated().compactMap { index, match in
                    hostIndicesToRemove.contains(index) ? nil : match
                }
                matched = preservedMatches
            }
        }

        // A CG-only surface cannot identify its hosting AX window. Safari can
        // retain an old, screen-sized player after exiting video fullscreen.
        // Keep a confirmed fullscreen surface independent; never redirect a
        // normal host to a residual player based on size or a unique host alone.

        // Preserve correspondências AX válidas mesmo quando uma janela
        // minimizada ou em outro Space não expõe geometria suficiente. As
        // superfícies restantes passam pelo fallback conservador, sem apagar
        // as identidades já resolvidas das outras janelas do aplicativo.
        guard !matched.isEmpty else { return consolidateAmbiguousApplicationSurfaces(candidates) }
        var matchedWindows = matched.map(\.window)
        if snapshotComplete && (isFinder || matchedAccessibilityWindowCount == accessibilityWindows.count) {
            var unassociatedPlayers = !isFinder
                ? remaining.filter { isDetachedFullScreenPresentation($0, accessibilityWindows: accessibilityWindows) }
                    .map { $0.withPresentation(windowID: $0.windowServerID) } : []
            if let onScreenPlayerIndex = unassociatedPlayers.firstIndex(where: \.isOnScreen),
               unassociatedPlayers.filter(\.isOnScreen).count == 1,
               !matchedWindows.contains(where: { $0.isOnScreen && $0.isAccessibilityFocused }) {
                let hadFocusedHost = matchedWindows.contains(where: \.isAccessibilityFocused) || isFrontmostApplication
                if hadFocusedHost {
                    matchedWindows = matchedWindows.map { $0.isOnScreen ? $0 : $0.withAccessibilityFocused(false) }
                    unassociatedPlayers[onScreenPlayerIndex] = unassociatedPlayers[onScreenPlayerIndex].withAccessibilityFocused(true)
                }
            }
            return matchedWindows + unassociatedPlayers
        }
        return matchedWindows + consolidateAmbiguousApplicationSurfaces(credibleFallbackCandidates(remaining))
    }

    private func accessibilityWindows(
        for ownerPID: pid_t,
        includeUtilityWindows: Bool
    ) -> [AccessibilityWindowSnapshot] {
        snapshotComplete = true
        if let cached = accessibilitySnapshotCache[ownerPID] {
            snapshotComplete = accessibilitySnapshotCompleteness[ownerPID] ?? true
            return cached
        }
        let deadline = min(refreshDeadline, ProcessInfo.processInfo.systemUptime + 0.12)
        let result = Self.liveAccessibilityWindows(
            for: ownerPID,
            includeUtilityWindows: includeUtilityWindows,
            deadline: deadline
        )
        snapshotComplete = result.complete
        return result.snapshots
    }

    /// AX calls may block inside third-party apps. Querying a small bounded
    /// pool prevents one unresponsive process from consuming the whole
    /// switcher opening budget, while each process still has its own deadline.
    private func collectAccessibilitySnapshots(
        for applications: [CapturedApplication],
        knownWindowIDsByPID: [pid_t: Set<CGWindowID>] = [:],
        includeUtilityWindows: Bool
    ) -> (snapshots: [pid_t: [AccessibilityWindowSnapshot]], completeness: [pid_t: Bool]) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = applications.filter { $0.processIdentifier != ownPID }
        guard !candidates.isEmpty else { return ([:], [:]) }
        let accumulator = AccessibilitySnapshotAccumulator()
        let group = DispatchGroup()
        let workers = DispatchSemaphore(value: 4)
        let queue = DispatchQueue(label: "com.taber.ax-snapshot", qos: .userInitiated, attributes: .concurrent)
        let globalDeadline = refreshDeadline

        for application in candidates {
            let pid = application.processIdentifier
            let knownWindowIDs = knownWindowIDsByPID[pid] ?? []
            group.enter()
            queue.async {
                defer { group.leave() }
                let remaining = globalDeadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0,
                      workers.wait(timeout: .now() + remaining) == .success else {
                    accumulator.store([], for: pid, complete: false)
                    return
                }
                defer { workers.signal() }
                let processDeadline = min(globalDeadline, ProcessInfo.processInfo.systemUptime + 0.12)
                let result = Self.liveAccessibilityWindows(
                    for: pid,
                    launchDate: application.launchDate,
                    knownWindowIDs: knownWindowIDs,
                    includeUtilityWindows: includeUtilityWindows,
                    deadline: processDeadline
                )
                accumulator.store(result.snapshots, for: pid, complete: result.complete)
            }
        }

        let remaining = max(0, globalDeadline - ProcessInfo.processInfo.systemUptime)
        let completedWithinBudget = group.wait(timeout: .now() + remaining) == .success
        let result = accumulator.snapshot()
        if !completedWithinBudget {
            snapshotComplete = false
        }
        return (result.values, result.completeness)
    }

    private nonisolated static func liveAccessibilityWindows(
        for ownerPID: pid_t,
        launchDate: Date? = nil,
        knownWindowIDs: Set<CGWindowID> = [],
        includeUtilityWindows: Bool,
        deadline: TimeInterval
    ) -> (snapshots: [AccessibilityWindowSnapshot], complete: Bool) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return ([], false) }
        let application = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.04)
        let focusedWindow = elementAttribute(kAXFocusedWindowAttribute as CFString, from: application)
        let mainWindow = elementAttribute(kAXMainWindowAttribute as CFString, from: application)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let primaryElements = value as? [AXUIElement] else { return ([], false) }
        var elements = primaryElements
        let primaryElementCount = primaryElements.count
        for extra in [focusedWindow, mainWindow].compactMap({ $0 }) {
            if !elements.contains(where: { CFEqual($0, extra) }) {
                elements.append(extra)
            }
        }
        for wid in knownWindowIDs.sorted() {
            if let cached = AXWindowReferenceCache.shared.element(ownerPID: ownerPID, launchDate: launchDate, windowID: wid),
               !elements.contains(where: { CFEqual($0, cached) }) {
                elements.append(cached)
            }
        }
        let attributes = [kAXSubroleAttribute, kAXTitleAttribute, kAXDocumentAttribute, kAXIdentifierAttribute,
                          kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
                          kAXFocusedAttribute, kAXMainAttribute, kAXRoleAttribute, "AXFullScreen"] as CFArray
        var snapshots: [AccessibilityWindowSnapshot] = []
        var seenWindowIDs = Set<CGWindowID>()
        var complete = true
        for (ordinal, element) in elements.enumerated() {
            let isPrimaryElement = ordinal < primaryElementCount
            guard ProcessInfo.processInfo.systemUptime < deadline, ordinal < 512 else {
                if isPrimaryElement { complete = false }
                break
            }
            AXUIElementSetMessagingTimeout(element, 0.04)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
                  let fields = values as? [Any], fields.count == 11 else {
                if isPrimaryElement { complete = false }
                continue
            }
            if !(fields[0] is String) || !(fields[9] is String) || !(fields[6] is NSNumber) {
                if isPrimaryElement { complete = false }
            }
            for field in fields where CFGetTypeID(field as CFTypeRef) == AXValueGetTypeID() {
                let value = field as! AXValue
                guard AXValueGetType(value) == .axError else { continue }
                var error = AXError.success
                if AXValueGetValue(value, .axError, &error),
                   error != .success && error != .attributeUnsupported && error != .noValue {
                    if isPrimaryElement { complete = false }
                }
            }
            let subrole = fields[0] as? String ?? ""
            let standard = subrole.isEmpty
                || subrole == kAXStandardWindowSubrole
                || subrole == kAXDialogSubrole
                || fields[9] as? String == kAXSheetRole
            let utility = includeUtilityWindows && (subrole == kAXFloatingWindowSubrole || subrole == kAXSystemFloatingWindowSubrole)
            guard standard || utility,
                  WindowEligibilityPolicy.isUserAccessibilitySurface(bundleIdentifier: "",
                      role: fields[9] as? String ?? "", subrole: subrole) else { continue }
            guard CFGetTypeID(fields[4] as CFTypeRef) == AXValueGetTypeID(),
                  CFGetTypeID(fields[5] as CFTypeRef) == AXValueGetTypeID() else {
                if isPrimaryElement { complete = false }
                continue
            }
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(fields[4] as! AXValue, .cgPoint, &position),
                  AXValueGetValue(fields[5] as! AXValue, .cgSize, &size),
                  position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else {
                if isPrimaryElement { complete = false }
                continue
            }
            let windowID = AccessibilityWindowIdentityResolver.windowID(for: element)
            if let windowID {
                guard seenWindowIDs.insert(windowID).inserted else { continue }
                AXWindowReferenceCache.shared.store(element, ownerPID: ownerPID, launchDate: launchDate, windowID: windowID)
            }
            snapshots.append(AccessibilityWindowSnapshot(
                windowID: windowID,
                identifier: fields[3] as? String ?? "", title: fields[1] as? String ?? "",
                document: fields[2] as? String ?? "", subrole: subrole,
                bounds: CGRect(origin: position, size: size),
                isMinimized: (fields[6] as? NSNumber)?.boolValue ?? false,
                isMain: ((fields[8] as? NSNumber)?.boolValue ?? false) || mainWindow.map { CFEqual(element, $0) } == true,
                isFocused: ((fields[7] as? NSNumber)?.boolValue ?? false) || focusedWindow.map { CFEqual(element, $0) } == true,
                ordinal: ordinal,
                role: fields[9] as? String ?? "",
                isNativeFullScreen: (fields[10] as? NSNumber)?.boolValue ?? false))
        }
        return (snapshots, complete)
    }

    private func isFullScreenSpace(_ windowID: CGWindowID?) -> Bool {
        guard let id = windowID else { return false }
        let space = injectedSpaces?[id] ?? (injectedSpaces == nil
            ? SpaceResolver.shared.resolve(windowIDs: [id])[id] : nil)
        return space?.isFullScreen == true
    }

    private func activationMode(
        for candidate: WindowInfo,
        accessibilityWindow: AccessibilityWindowSnapshot
    ) -> WindowActivationMode {
        // Um ID exato de janela é conclusivo para superfícies comuns. Evita
        // consultar a geometria de todas as telas no hot path e mantém a
        // exceção de dialogs usados por players fullscreen customizados.
        if accessibilityWindow.windowID == candidate.windowServerID,
           accessibilityWindow.subrole != kAXDialogSubrole as String {
            return .raiseWindow
        }
        // Geometry is only supporting evidence for browser player dialogs.
        guard isBrowser(candidate.bundleIdentifier),
              accessibilityWindow.subrole == kAXDialogSubrole as String else { return .raiseWindow }
        let isPresentationSized = candidate.isFullScreen
            || accessibilityWindow.isNativeFullScreen
            || isFullScreenSpace(candidate.windowServerID)
            || isFullScreenWindow(candidate.bounds)
            || isFullScreenWindow(accessibilityWindow.bounds)
        guard isPresentationSized else {
            return .raiseWindow
        }

        return WindowMatchingPolicy.requiresApplicationActivation(
            isPresentationSized: true,
            hasExactWindowIDMatch: accessibilityWindow.windowID == candidate.windowServerID,
            isDialog: accessibilityWindow.subrole == kAXDialogSubrole as String,
            candidateTitle: candidate.title,
            candidateBounds: candidate.bounds,
            accessibilityTitle: accessibilityWindow.title,
            accessibilityBounds: accessibilityWindow.bounds
        ) ? .activateApplication : .raiseWindow
    }

    private func isDetachedFullScreenPresentation(
        _ candidate: WindowInfo,
        accessibilityWindows: [AccessibilityWindowSnapshot]
    ) -> Bool {
        let inFullScreenSpace = isFullScreenSpace(candidate.windowServerID)
        let isPresentationSized = candidate.isFullScreen
            || isFullScreenWindow(candidate.bounds)
            || (inFullScreenSpace && coversMostOfScreen(candidate.bounds))
        guard isPresentationSized else { return false }
        // Geometry and absence from AX do not prove fullscreen.
        guard inFullScreenSpace else { return false }
        let allFallbackMatchesRequireApplicationActivation = accessibilityWindows.allSatisfy { accessibilityWindow in
            activationMode(
                for: candidate,
                accessibilityWindow: accessibilityWindow
            ) == .activateApplication
        }
        return WindowMatchingPolicy.isDetachedPresentationCandidate(
            isPresentationSized: isPresentationSized,
            candidateWindowID: candidate.windowServerID ?? 0,
            accessibilityWindowIDs: accessibilityWindows.map(\.windowID),
            fallbackRequiresApplicationActivation: allFallbackMatchesRequireApplicationActivation
        )
    }

    private func fillsVisibleScreen(_ windowBounds: CGRect) -> Bool {
        let cocoaBounds = cocoaScreenCoordinates(for: windowBounds)
        return screens.contains { screen in
            approximatelyEqual(cocoaBounds, screen.visibleFrame, tolerance: 16)
                || approximatelyEqual(cocoaBounds, screen.frame, tolerance: 16)
        }
    }

    private func coversMostOfScreen(_ windowBounds: CGRect) -> Bool {
        let cocoaBounds = cocoaScreenCoordinates(for: windowBounds)
        return screens.contains { screen in
            let intersection = cocoaBounds.intersection(screen.frame)
            guard !intersection.isNull, screen.frame.width > 0, screen.frame.height > 0 else {
                return false
            }
            let widthCoverage = intersection.width / screen.frame.width
            let heightCoverage = intersection.height / screen.frame.height
            return widthCoverage >= 0.90 && heightCoverage >= 0.88
        }
    }

    private func matchScore(
        _ candidate: WindowInfo,
        _ accessibilityWindow: AccessibilityWindowSnapshot,
        candidateVisualOrder: Int
    ) -> Int? {
        WindowMatchingPolicy.fallbackScore(
            candidateTitle: candidate.title,
            candidateBounds: candidate.bounds,
            candidateIsMinimized: candidate.isMinimized,
            candidateOrdinal: 0,
            accessibilityTitle: accessibilityWindow.title,
            accessibilityBounds: accessibilityWindow.bounds,
            accessibilityIsMinimized: accessibilityWindow.isMinimized,
            accessibilityOrdinal: 0
        )
    }

    private func disambiguateRepeatedTitles(in windows: [WindowInfo]) -> [WindowInfo] {
        let groups = Dictionary(grouping: windows.indices) { index in
            let window = windows[index]
            return "\(window.ownerPID)|\(normalized(window.displayTitle))"
        }

        var result = windows
        for indices in groups.values where indices.count > 1 {
            for (offset, index) in indices.enumerated() {
                result[index] = windows[index].withTitleOccurrence(offset + 1, count: indices.count)
            }
        }
        return result
    }

    private func deduplicateByGeometry(_ candidates: [WindowInfo]) -> [WindowInfo] {
        // Geometry and title are not identities (Finder, private browsing).
        var seen = Set<WindowIdentity>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private func consolidateAmbiguousApplicationSurfaces(_ candidates: [WindowInfo]) -> [WindowInfo] {
        // Different WindowServer IDs remain different destinations, even when
        // their titles or geometry happen to be identical.
        deduplicateByGeometry(candidates).map { candidate in
            guard let previous = previouslyResolvedAccessibilityWindow(for: candidate),
                  let ordinal = previous.accessibilityOrdinal else {
                return candidate.withActivationMode(.activateApplication)
            }
            // A failed AX refresh is not evidence that an established AX
            // target became a CG-only renderer. Keep the strong activation
            // route so it can revalidate/use its cached AX reference.
            let preserved = candidate.withAccessibilityIdentity(
                identifier: previous.accessibilityIdentifier, ordinal: ordinal,
                accessibilityTitle: previous.title, isMinimized: previous.isMinimized,
                isFullScreen: previous.isFullScreen, isFocused: false,
                activationMode: previous.activationMode)
            if let presentationID = previous.presentationWindowID {
                return preserved.withPresentation(windowID: presentationID)
                    .withActivationMode(previous.activationMode)
            }
            return preserved
        }
    }

    private func previouslyResolvedAccessibilityWindow(for candidate: WindowInfo) -> WindowInfo? {
        guard !snapshotComplete else { return nil }
        return windows.first { previous in
            previous.id == candidate.id
                && previous.ownerPID == candidate.ownerPID
                && previous.processLaunchDate == candidate.processLaunchDate
                && previous.activationPID == candidate.activationPID
                && previous.activationProcessLaunchDate == candidate.activationProcessLaunchDate
                && previous.activationMode == .raiseWindow
                && previous.accessibilityOrdinal != nil
        }
    }

    private func credibleFallbackCandidates(_ candidates: [WindowInfo]) -> [WindowInfo] {
        candidates.filter { candidate in
            candidate.isOnScreen
                || candidate.isFullScreen
                || !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || previouslyResolvedAccessibilityWindow(for: candidate) != nil
        }
    }

    private nonisolated static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private nonisolated static func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private nonisolated static func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func bounds(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 8
            && abs(lhs.minY - rhs.minY) <= 8
            && abs(lhs.width - rhs.width) <= 8
            && abs(lhs.height - rhs.height) <= 8
    }

    private func screenName(for windowBounds: CGRect) -> String {
        guard screens.count > 1 else { return "" }
        let cocoaBounds = cocoaScreenCoordinates(for: windowBounds)
        return screens.max { lhs, rhs in
            intersectionArea(lhs.frame, cocoaBounds) < intersectionArea(rhs.frame, cocoaBounds)
        }?.localizedName ?? ""
    }

    private func isFullScreenWindow(_ windowBounds: CGRect) -> Bool {
        let cocoaBounds = cocoaScreenCoordinates(for: windowBounds)
        return screens.contains { screen in
            if approximatelyEqual(cocoaBounds, screen.frame, tolerance: 12) {
                return true
            }
            // Em MacBooks com notch, janelas e players em Space de Tela Cheia
            // ocupam toda a área abaixo da barra/câmera (ex.: 38pt do topo).
            let matchesHorizontal = abs(cocoaBounds.minX - screen.frame.minX) <= 12
                && abs(cocoaBounds.width - screen.frame.width) <= 12
            let touchesBottom = abs(cocoaBounds.minY - screen.frame.minY) <= 12
            let topInset = screen.frame.maxY - cocoaBounds.maxY
            let reachesBelowNotchOrMenuBar = topInset >= -12 && topInset <= 48
            return matchesHorizontal && touchesBottom && reachesBelowNotchOrMenuBar
        }
    }

    private func cocoaScreenCoordinates(for cgBounds: CGRect) -> CGRect {
        let mainScreenTop = screens.first?.frame.maxY ?? 0
        return CGRect(
            x: cgBounds.minX,
            y: mainScreenTop - cgBounds.maxY,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func isBrowser(_ bundleIdentifier: String) -> Bool {
        let knownBrowserIdentifiers = [
            "com.apple.Safari",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
            "com.brave.Browser",
            "com.operasoftware.Opera",
            "com.vivaldi.Vivaldi",
            "app.zen-browser.zen"
        ]
        return knownBrowserIdentifiers.contains { identifier in
            bundleIdentifier == identifier || bundleIdentifier.hasPrefix(identifier + ".")
        }
    }

    private func responsibleActivationApplication(
        for owner: CapturedApplication,
        among applications: [pid_t: CapturedApplication]
    ) -> CapturedApplication {
        guard let ownerURL = owner.bundleURL,
              let hostBundleIdentifier = outermostApplicationBundleIdentifier(for: ownerURL),
              hostBundleIdentifier != owner.bundleIdentifier
        else { return owner }

        return applications.values
            .filter { $0.bundleIdentifier == hostBundleIdentifier && !$0.isTerminated }
            .sorted { lhs, rhs in
                if lhs.activationPolicy != rhs.activationPolicy {
                    return lhs.activationPolicy == .regular
                }
                return lhs.processIdentifier < rhs.processIdentifier
            }
            .first ?? owner
    }

    private func outermostApplicationBundleIdentifier(for bundleURL: URL) -> String? {
        let components = bundleURL.standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let appPath = NSString.path(withComponents: Array(components.prefix(through: appIndex)))
        return Bundle(path: appPath)?.bundleIdentifier
    }

}
