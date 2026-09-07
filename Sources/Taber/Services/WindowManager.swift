import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import os

struct AccessibilityWindowSnapshot {
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
}

/// Injectable snapshots keep WindowServer/AX integration out of deterministic tests.
@MainActor
protocol WindowSnapshotSource {
    var frontmostPID: pid_t? { get }
    func candidates(includeUtilityWindows: Bool) -> [WindowInfo]
    func accessibilityWindows(for pid: pid_t, includeUtilityWindows: Bool) -> [AccessibilityWindowSnapshot]
    func spaces(for ids: [CGWindowID]) -> [CGWindowID: ResolvedWindowSpace]
}

@MainActor
final class WindowManager {
    private let source: (any WindowSnapshotSource)?
    init(source: (any WindowSnapshotSource)? = nil) { self.source = source }
    private(set) var windows: [WindowInfo] = []
    private var applicationIconCache: [pid_t: NSImage] = [:]
    private var exactMatchesInRefresh = 0
    private var didReportIdentityResolver = false
    private var refreshDeadline = TimeInterval.greatestFiniteMagnitude
    private var snapshotComplete = true
    private var screens: [NSScreen] = []
    private let logger = Logger(subsystem: "com.taber.app", category: "windows")

    func refresh(includeUtilityWindows: Bool = false) {
        screens = NSScreen.screens
        refreshDeadline = ProcessInfo.processInfo.systemUptime + 0.32
        if let source {
            windows = reconcile(source.candidates(includeUtilityWindows: includeUtilityWindows),
                frontmostPID: source.frontmostPID, includeUtilityWindows: includeUtilityWindows)
            return
        }
        let refreshStartedAt = ContinuousClock.now
        exactMatchesInRefresh = 0
        if !didReportIdentityResolver {
            logger.notice(
                "Identidade AX-WindowServer disponível=\(AccessibilityWindowIdentityResolver.isAvailable)"
            )
            didReportIdentityResolver = true
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let workspace = NSWorkspace.shared
        let frontmostPID = workspace.frontmostApplication?.processIdentifier
        let runningApplications: [pid_t: NSRunningApplication] = Dictionary(uniqueKeysWithValues: workspace.runningApplications.compactMap { application -> (pid_t, NSRunningApplication)? in
            guard application.localizedName != nil else { return nil }
            return (application.processIdentifier, application)
        })

        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            windows = []
            return
        }

        var activePIDs = Set<pid_t>()
        let rawCandidates: [WindowInfo] = windowList.compactMap { info in
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
            let bundleIdentifier = application.bundleIdentifier ?? ""
            let bundlePath = application.bundleURL?.path ?? ""
            let eligibility = WindowEligibilityContext(
                bundleIdentifier: bundleIdentifier,
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
            let icon: NSImage?
            if let cachedIcon = applicationIconCache[ownerPID] {
                icon = cachedIcon
            } else {
                icon = application.icon
                applicationIconCache[ownerPID] = icon
            }

            return WindowInfo(
                id: windowID,
                ownerPID: ownerPID,
                bundleIdentifier: bundleIdentifier,
                applicationName: application.localizedName ?? "Aplicativo",
                title: title,
                bounds: bounds,
                isOnScreen: isOnScreen,
                // Fora da tela também pode significar outro Space. O estado
                // minimizado verdadeiro será reconciliado via Acessibilidade.
                isMinimized: false,
                isFullScreen: isFullScreenWindow(bounds),
                screenName: screenName(for: bounds),
                icon: icon,
                processLaunchDate: application.launchDate
            )
        }

        windows = reconcile(rawCandidates, frontmostPID: frontmostPID, includeUtilityWindows: includeUtilityWindows)
        let elapsed = refreshStartedAt.duration(to: .now)
        logger.notice("Varredura: janelas=\(self.windows.count) duração=\(String(describing: elapsed), privacy: .public)")
        applicationIconCache = applicationIconCache.filter { activePIDs.contains($0.key) }
    }

    private func reconcile(_ rawCandidates: [WindowInfo], frontmostPID: pid_t?, includeUtilityWindows: Bool) -> [WindowInfo] {
        let candidatesByPID = Dictionary(grouping: rawCandidates, by: \.ownerPID)
        var canonicalWindowsByID: [CGWindowID: WindowInfo] = [:]

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
                isFrontmostApplication: ownerPID == frontmostPID
            )
            for window in selected {
                canonicalWindowsByID[window.id] = window
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
        let originalIDs = Set(rawCandidates.map(\.id))
        let canonicalWindows = rawCandidates.compactMap { canonicalWindowsByID[$0.id] }
            + canonicalWindowsByID.values.filter { !originalIDs.contains($0.id) }.sorted { $0.id < $1.id }
        // Consultar o Space exige uma chamada ao WindowServer por janela.
        // Faça isso somente depois de remover superfícies auxiliares.
        let resolvedSpaces = source?.spaces(for: canonicalWindows.map(\.id))
            ?? SpaceResolver.shared.resolve(windowIDs: canonicalWindows.map(\.id))
        let resolvedWindows = canonicalWindows.map { window in
            window.withResolvedSpace(resolvedSpaces[window.id])
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
        let needsAccessibilityReconciliation = WindowMatchingPolicy.shouldReconcileWithAccessibility(
            candidateCount: candidates.count,
            containsOffscreenWindow: candidates.contains(where: { !$0.isOnScreen }),
            containsFullScreenWindow: candidates.contains(where: { $0.isFullScreen }),
            isFrontmostApplication: isFrontmostApplication
        )
        guard needsAccessibilityReconciliation else { return candidates }

        let accessibilityWindows = accessibilityWindows(
            for: ownerPID,
            includeUtilityWindows: includeUtilityWindows
        )

        guard !accessibilityWindows.isEmpty else {
            // Alguns processos regulares mantêm superfícies 500×500 vazias
            // no WindowServer mesmo sem possuir uma janela alternável. Sem
            // confirmação AX, preserve apenas superfícies com evidência real.
            let credibleCandidates = candidates.filter { candidate in
                candidate.isOnScreen
                    || candidate.isFullScreen
                    || !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return deduplicateByGeometry(credibleCandidates)
        }

        var remaining = candidates
        var matched: [(window: WindowInfo, accessibility: AccessibilityWindowSnapshot)] = []
        let visualOrderByID = Dictionary(
            uniqueKeysWithValues: candidates.enumerated().map { ($0.element.id, $0.offset) }
        )

        for accessibilityWindow in accessibilityWindows {
            let bestIndex: Int?
            if let exactWindowID = accessibilityWindow.windowID,
               let exactIndex = remaining.firstIndex(where: { $0.id == exactWindowID }) {
                bestIndex = exactIndex
                exactMatchesInRefresh += 1
            } else if accessibilityWindow.windowID == nil {
                let scored = remaining.enumerated().compactMap { index, candidate -> (Int, Int)? in
                    let visualOrder = visualOrderByID[candidate.id, default: index]
                    guard let score = matchScore(
                        candidate,
                        accessibilityWindow,
                        candidateVisualOrder: visualOrder
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
                if let id = accessibilityWindow.windowID, accessibilityWindow.isMinimized,
                   let template = candidates.first {
                    let recovered = WindowInfo(id: id, ownerPID: ownerPID,
                        bundleIdentifier: template.bundleIdentifier, applicationName: template.applicationName,
                        title: accessibilityWindow.title, bounds: accessibilityWindow.bounds,
                        isOnScreen: false, isMinimized: true, icon: template.icon,
                        accessibilityIdentifier: accessibilityWindow.identifier,
                        accessibilityOrdinal: accessibilityWindow.ordinal,
                        processLaunchDate: template.processLaunchDate)
                    matched.append((recovered, accessibilityWindow))
                }
                continue
            }
            let candidate = remaining.remove(at: bestIndex)
            let candidateActivationMode = activationMode(
                for: candidate,
                accessibilityWindow: accessibilityWindow
            )
            if candidateActivationMode == .activateApplication {
                logger.notice(
                    "Fullscreen de conteúdo detectado: pid=\(ownerPID) janela=\(candidate.id)"
                )
            }
            matched.append((
                window: candidate.withAccessibilityIdentity(
                    identifier: accessibilityWindow.identifier,
                    ordinal: accessibilityWindow.ordinal,
                    accessibilityTitle: accessibilityWindow.title,
                    isMinimized: accessibilityWindow.isMinimized,
                    isFullScreen: candidate.isFullScreen
                        || candidateActivationMode == .activateApplication,
                    isFocused: accessibilityWindow.isFocused,
                    activationMode: candidateActivationMode
                ),
                accessibility: accessibilityWindow
            ))
        }
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
                )
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

        // Safari, Chrome e outros navegadores podem manter a janela AX normal
        // e criar outra superfície CG para o fullscreen do player. Ela sobra
        // após a reconciliação porque não existe em kAXWindows. Associe-a à
        // janela principal/focada e preserve seu ID para miniatura e Space.
        if candidates.first.map({ isBrowser($0.bundleIdentifier) }) == true,
           let presentationIndex = remaining.firstIndex(where: { candidate in
            isDetachedFullScreenPresentation(
                candidate,
                accessibilityWindows: accessibilityWindows
            )
        }), let hostIndex = matched.firstIndex(where: { $0.accessibility.isFocused }) {
            remaining.remove(at: presentationIndex)
            let hostMatch = matched[hostIndex]
            let host = hostMatch.accessibility
            matched[hostIndex].window = hostMatch.window.withAccessibilityIdentity(
                identifier: host.identifier,
                ordinal: host.ordinal,
                accessibilityTitle: host.title,
                isMinimized: host.isMinimized,
                isFullScreen: true,
                isFocused: host.isFocused,
                activationMode: .activateApplication
            )
        }

        // Preserve correspondências AX válidas mesmo quando uma janela
        // minimizada ou em outro Space não expõe geometria suficiente. As
        // superfícies restantes passam pelo fallback conservador, sem apagar
        // as identidades já resolvidas das outras janelas do aplicativo.
        guard !matched.isEmpty else { return deduplicateByGeometry(candidates) }
        let matchedWindows = matched.map(\.window)
        if matchedAccessibilityWindowCount == accessibilityWindows.count && snapshotComplete {
            return matchedWindows
        }
        return matchedWindows + deduplicateByGeometry(credibleFallbackCandidates(remaining))
    }

    private func accessibilityWindows(
        for ownerPID: pid_t,
        includeUtilityWindows: Bool
    ) -> [AccessibilityWindowSnapshot] {
        snapshotComplete = true
        if let source { return source.accessibilityWindows(for: ownerPID, includeUtilityWindows: includeUtilityWindows) }
        let deadline = min(refreshDeadline, ProcessInfo.processInfo.systemUptime + 0.12)
        guard ProcessInfo.processInfo.systemUptime < deadline else { snapshotComplete = false; return [] }
        let application = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.04)
        let focusedWindow = elementAttribute(kAXFocusedWindowAttribute as CFString, from: application)
        let mainWindow = elementAttribute(kAXMainWindowAttribute as CFString, from: application)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { snapshotComplete = false; return [] }
        let attributes = [kAXSubroleAttribute, kAXTitleAttribute, kAXDocumentAttribute, kAXIdentifierAttribute,
                          kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
                          kAXFocusedAttribute, kAXMainAttribute] as CFArray
        var snapshots: [AccessibilityWindowSnapshot] = []
        for (ordinal, element) in elements.enumerated() {
            guard ProcessInfo.processInfo.systemUptime < deadline, ordinal < 512 else {
                snapshotComplete = false; break
            }
            AXUIElementSetMessagingTimeout(element, 0.04)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
                  let fields = values as? [Any], fields.count == 9 else { snapshotComplete = false; continue }
            let subrole = fields[0] as? String ?? ""
            let standard = subrole.isEmpty || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            let utility = includeUtilityWindows && (subrole == kAXFloatingWindowSubrole || subrole == kAXSystemFloatingWindowSubrole)
            guard standard || utility else { continue }
            guard CFGetTypeID(fields[4] as CFTypeRef) == AXValueGetTypeID(),
                  CFGetTypeID(fields[5] as CFTypeRef) == AXValueGetTypeID() else { continue }
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(fields[4] as! AXValue, .cgPoint, &position),
                  AXValueGetValue(fields[5] as! AXValue, .cgSize, &size) else { continue }
            snapshots.append(AccessibilityWindowSnapshot(
                windowID: AccessibilityWindowIdentityResolver.windowID(for: element),
                identifier: fields[3] as? String ?? "", title: fields[1] as? String ?? "",
                document: fields[2] as? String ?? "", subrole: subrole,
                bounds: CGRect(origin: position, size: size),
                isMinimized: (fields[6] as? NSNumber)?.boolValue ?? false,
                isMain: ((fields[8] as? NSNumber)?.boolValue ?? false) || mainWindow.map { CFEqual(element, $0) } == true,
                isFocused: ((fields[7] as? NSNumber)?.boolValue ?? false) || focusedWindow.map { CFEqual(element, $0) } == true,
                ordinal: ordinal))
        }
        return snapshots
    }

    private func activationMode(
        for candidate: WindowInfo,
        accessibilityWindow: AccessibilityWindowSnapshot
    ) -> WindowActivationMode {
        let isPresentationSized = candidate.isFullScreen
            || fillsVisibleScreen(candidate.bounds)
            || coversMostOfScreen(candidate.bounds)
        guard isPresentationSized else {
            return .raiseWindow
        }

        return WindowMatchingPolicy.requiresApplicationActivation(
            isPresentationSized: true,
            hasExactWindowIDMatch: accessibilityWindow.windowID == candidate.id,
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
        let allFallbackMatchesRequireApplicationActivation = accessibilityWindows.allSatisfy { accessibilityWindow in
            activationMode(
                for: candidate,
                accessibilityWindow: accessibilityWindow
            ) == .activateApplication
        }
        return WindowMatchingPolicy.isDetachedPresentationCandidate(
            isPresentationSized: candidate.isFullScreen
                || fillsVisibleScreen(candidate.bounds)
                || coversMostOfScreen(candidate.bounds),
            candidateWindowID: candidate.id,
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

        var occurrenceByWindowID: [CGWindowID: (occurrence: Int, count: Int)] = [:]
        for indices in groups.values where indices.count > 1 {
            for (offset, index) in indices.enumerated() {
                occurrenceByWindowID[windows[index].id] = (offset + 1, indices.count)
            }
        }

        return windows.map { window in
            guard let occurrence = occurrenceByWindowID[window.id] else { return window }
            return window.withTitleOccurrence(occurrence.occurrence, count: occurrence.count)
        }
    }

    private func deduplicateByGeometry(_ candidates: [WindowInfo]) -> [WindowInfo] {
        // Geometry and title are not identities (Finder, private browsing).
        var seen = Set<CGWindowID>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private func credibleFallbackCandidates(_ candidates: [WindowInfo]) -> [WindowInfo] {
        candidates.filter { candidate in
            candidate.isOnScreen
                || candidate.isFullScreen
                || !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
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
            approximatelyEqual(cocoaBounds, screen.frame, tolerance: 12)
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

    func windows(forApplicationID applicationID: String) -> [WindowInfo] {
        windows.filter { $0.applicationIdentifier == applicationID }
    }

    func frontmostWindow() -> WindowInfo? {
        let frontmostPID = source.map { $0.frontmostPID } ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = windows.map {
            (
                ownerPID: $0.ownerPID,
                isMinimized: $0.isMinimized,
                isFocused: $0.isAccessibilityFocused
            )
        }
        guard let index = WindowMatchingPolicy.preferredFrontmostIndex(
            frontmostPID: frontmostPID,
            candidates: candidates
        ) else { return nil }
        return windows[index]
    }

    func activate(_ window: WindowInfo) {
        AccessibilityService.restoreAndRaise(window: window)
    }
}
