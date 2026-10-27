import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import OSLog

@MainActor
protocol WindowActivationDriving {
    func resolve(_ window: WindowInfo) -> WindowResolution
    func setDeadline(_ deadline: TimeInterval)
    func restore()
    func focus()
    func activateApplication()
    var isMinimized: Bool { get }
    func confirmation(of window: WindowInfo) -> WindowActivationConfirmation
}

enum WindowResolution: Equatable { case found, temporarilyUnavailable, omittedOffSpace, absent, ambiguous }
enum WindowActivationConfirmation { case pending, confirmed, applicationActivated, missing }

extension WindowActivationDriving {
    func setDeadline(_ deadline: TimeInterval) {}
}

/// Drivers that can validate an application-only target without requiring an
/// AX window. This is important for games and custom renderers that expose a
/// credible WindowServer surface but no usable accessibility tree.
@MainActor
protocol ApplicationOnlyActivationDriving {
    func validateApplicationTarget(_ window: WindowInfo) -> Bool
}

/// Optional stronger validation used before touching AX. Test drivers and
/// other deterministic adapters can keep implementing only the base protocol.
@MainActor
protocol ProcessValidatingActivationDriving {
    func validateProcess(_ window: WindowInfo) -> Bool
}

enum WindowActivationRejection: String, Equatable {
    case ambiguousTarget
    case staleProcess
    case targetNotFound
    case localActivationFailed
    case timedOut
    case cancelled
}

enum WindowActivationStep: String, Equatable {
    case processValidated
    case targetResolved
    case restored
    case applicationActivated
    case focusedAndRaised
    case retryScheduled
}

struct WindowActivationResult: Equatable {
    enum Outcome: Equatable {
        case requested
        case applicationActivated
        case activated
        case rejected(WindowActivationRejection)
    }

    let strategy: WindowMatchingPolicy.ActivationStrategy
    let outcome: Outcome
    let steps: [WindowActivationStep]

    var succeeded: Bool { outcome == .activated }
}

@MainActor
protocol ActivationClock {
    func schedule(after delay: Duration, operation: @escaping @MainActor () -> Void)
}

@MainActor
struct SystemActivationClock: ActivationClock {
    func schedule(after delay: Duration, operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            operation()
        }
    }
}

/// One cancellable transaction; resolution, actions and observation share a deadline.
@MainActor
final class WindowActivationCoordinator {
    private var generation: UInt = 0
    private let driver: (WindowInfo) -> any WindowActivationDriving
    private let clock: any ActivationClock
    private let now: () -> TimeInterval
    private var pendingResult: WindowActivationResult?
    var onResult: ((WindowActivationResult) -> Void)?

    init(clock: any ActivationClock = SystemActivationClock(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         driver: @escaping (WindowInfo) -> any WindowActivationDriving) {
        self.clock = clock; self.now = now; self.driver = driver
    }

    @discardableResult
    func activate(_ window: WindowInfo) -> WindowActivationResult {
        cancelPending()
        let target = driver(window)
        let deadline = now() + 2
        target.setDeadline(deadline)
        return attempt(window, target: target, request: generation, deadline: deadline,
                       remaining: 10, steps: [], hasActed: false)
    }

    private func attempt(_ window: WindowInfo, target: any WindowActivationDriving,
                         request: UInt, deadline: TimeInterval, remaining: Int,
                         steps: [WindowActivationStep], hasActed: Bool) -> WindowActivationResult {
        let strategy = WindowMatchingPolicy.activationStrategy(
            // A minimized window must be resolved through AX first so we can
            // explicitly clear AXMinimized. Activating its application alone
            // leaves a Command-M window in the Dock for several apps.
            usesApplicationOnlyActivation: window.activationMode == .activateApplication && !window.isMinimized,
            hasRegisteredLocalTarget: false)
        var steps = steps
        func finish(_ outcome: WindowActivationResult.Outcome) -> WindowActivationResult {
            let result = WindowActivationResult(strategy: strategy, outcome: outcome, steps: steps)
            pendingResult = outcome == .requested ? result : nil
            onResult?(result)
            return result
        }
        guard now() < deadline, remaining > 0 else { return finish(.rejected(.timedOut)) }
        if let validating = target as? any ProcessValidatingActivationDriving {
            guard validating.validateProcess(window) else { return finish(.rejected(.staleProcess)) }
            if !steps.contains(.processValidated) { steps.append(.processValidated) }
        }

        // Observe once per retry, before acting. Visibility alone is never strong success.
        if hasActed {
            switch target.confirmation(of: window) {
            case .confirmed: return finish(.activated)
            case .applicationActivated: return finish(.applicationActivated)
            case .missing: return finish(.rejected(.targetNotFound))
            case .pending: break
            }
        }
        var acted = hasActed
        if strategy == .application, let validator = target as? any ApplicationOnlyActivationDriving {
            guard validator.validateApplicationTarget(window) else { return finish(.rejected(.targetNotFound)) }
            guard now() < deadline else { return finish(.rejected(.timedOut)) }
            target.activateApplication(); acted = true
            if !steps.contains(.applicationActivated) { steps.append(.applicationActivated) }
        } else {
            switch target.resolve(window) {
            case .absent: return finish(.rejected(.targetNotFound))
            case .ambiguous: return finish(.rejected(.ambiguousTarget))
            case .temporarilyUnavailable:
                break
            case .omittedOffSpace:
                if remaining < 10, !window.isMinimized,
                   let validator = target as? any ApplicationOnlyActivationDriving,
                   validator.validateApplicationTarget(window) {
                    guard now() < deadline else { return finish(.rejected(.timedOut)) }
                    target.activateApplication(); acted = true
                    if !steps.contains(.applicationActivated) { steps.append(.applicationActivated) }
                }
            case .found:
                if !steps.contains(.targetResolved) { steps.append(.targetResolved) }
                guard now() < deadline else { return finish(.rejected(.timedOut)) }
                if strategy != .application {
                    if target.isMinimized {
                        target.restore()
                        if !steps.contains(.restored) { steps.append(.restored) }
                    }
                    // Select the destination before activation can initiate a Space transition.
                    target.focus()
                    if !steps.contains(.focusedAndRaised) { steps.append(.focusedAndRaised) }
                }
                guard now() < deadline else { return finish(.rejected(.timedOut)) }
                target.activateApplication(); acted = true
                if !steps.contains(.applicationActivated) { steps.append(.applicationActivated) }
            }
        }
        // Activation is asynchronous. First confirmation happens on the next tick.
        if !steps.contains(.retryScheduled) { steps.append(.retryScheduled) }
        let result = finish(.requested)
        clock.schedule(after: .milliseconds(200)) { [weak self] in
            guard let self, self.generation == request else { return }
            _ = self.attempt(window, target: target, request: request, deadline: deadline,
                             remaining: remaining - 1, steps: steps, hasActed: acted)
        }
        return result
    }

    func cancelPending() {
        generation &+= 1
        if let pendingResult {
            self.pendingResult = nil
            onResult?(.init(strategy: pendingResult.strategy, outcome: .rejected(.cancelled), steps: pendingResult.steps))
        }
    }
}

/// AX references are opaque handles. The lock protects the dictionary, never an AX call.
/// The caller must validate PID, launch date and window ID before using a returned handle.
final class AXWindowReferenceCache: @unchecked Sendable {
    static let shared = AXWindowReferenceCache()
    struct Key: Hashable { let ownerPID: pid_t; let launchDate: Date?; let windowID: CGWindowID }
    private let lock = NSLock()
    private var entries: [Key: AXUIElement] = [:]
    func store(_ element: AXUIElement, ownerPID: pid_t, launchDate: Date?, windowID: CGWindowID) {
        guard windowID != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        entries[Key(ownerPID: ownerPID, launchDate: launchDate, windowID: windowID)] = element
    }
    func element(ownerPID: pid_t, launchDate: Date?, windowID: CGWindowID) -> AXUIElement? {
        guard windowID != 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return entries[Key(ownerPID: ownerPID, launchDate: launchDate, windowID: windowID)]
    }
    func remove(ownerPID: pid_t, windowID: CGWindowID? = nil) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.key.ownerPID != ownerPID || (windowID != nil && $0.key.windowID != windowID) }
    }
    func retain(liveWindows: Set<CGWindowID>, processes: [pid_t: Date?]) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter {
            guard liveWindows.contains($0.key.windowID),
                  let knownLaunchDate = processes[$0.key.ownerPID] else { return false }
            return knownLaunchDate == $0.key.launchDate
        }
    }
}

@MainActor
enum AccessibilityService {
    typealias LocalWindowActivator = @MainActor () -> Bool

    private static let logger = Logger(subsystem: "com.taber.app", category: "activation")
    private static let coordinator = WindowActivationCoordinator { AXWindowActivationDriver(window: $0) }
    private static var localWindowActivators: [WindowInfo.ID: LocalWindowActivator] = [:]
    private(set) static var lastActivationResult: WindowActivationResult?
    private(set) static var pendingTargetWindow: WindowInfo?
    static var onTargetConfirmed: ((WindowInfo) -> Void)?
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        requestAccess()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Registers only real local user windows (currently Settings). Internal
    /// overlays remain absent from this registry and can never be activated by
    /// accidentally matching Taber's own PID.
    static func registerLocalWindow(
        id: WindowInfo.ID,
        activator: @escaping LocalWindowActivator
    ) {
        localWindowActivators[id] = activator
    }

    static func unregisterLocalWindow(id: WindowInfo.ID) {
        localWindowActivators.removeValue(forKey: id)
    }

    @discardableResult
    static func restoreAndRaise(window: WindowInfo) -> WindowActivationResult {
        coordinator.cancelPending()
        pendingTargetWindow = window
        let started = ProcessInfo.processInfo.systemUptime
        coordinator.onResult = { result in
            lastActivationResult = result
            switch result.outcome {
            case .requested:
                pendingTargetWindow = window
            case .activated, .applicationActivated:
                if pendingTargetWindow?.id == window.id {
                    pendingTargetWindow = nil
                }
                onTargetConfirmed?(window)
            case .rejected:
                if pendingTargetWindow?.id == window.id {
                    pendingTargetWindow = nil
                }
            }
            TaberDiagnostics.recordActivation(window, result: result, started: started)
            logger.notice("Activation progress=\(String(describing: result.outcome), privacy: .public)")
        }
        let result: WindowActivationResult
        if let activateLocalWindow = localWindowActivators[window.id] {
            let activated = activateLocalWindow()
            pendingTargetWindow = nil
            result = WindowActivationResult(
                strategy: .localWindow,
                outcome: activated ? .activated : .rejected(.localActivationFailed),
                steps: []
            )
            if activated { onTargetConfirmed?(window) }
        } else {
            result = coordinator.activate(window)
        }
        lastActivationResult = result
        logger.notice(
            "Activation ownerPID=\(window.ownerPID) activationPID=\(window.activationPID) strategy=\(result.strategy.rawValue, privacy: .public) result=\(String(describing: result.outcome), privacy: .public) steps=\(result.steps.map(\.rawValue).joined(separator: ","), privacy: .public)"
        )
        return result
    }
    static func cancelPendingRestoration() {
        pendingTargetWindow = nil
        coordinator.cancelPending()
    }
}

struct ActivationCandidate {
    let windowID: CGWindowID?
    let identifier: String
    let title: String
    let bounds: CGRect?
    let isMinimized: Bool
    let ordinal: Int
}

extension WindowMatchingPolicy {
    static func activationCandidateIndex(for window: WindowInfo, in candidates: [ActivationCandidate]) -> Int? {
        if let windowServerID = window.windowServerID {
            let exactMatches = candidates.indices.filter { candidates[$0].windowID == windowServerID }
            if exactMatches.count == 1 { return exactMatches[0] }
            if exactMatches.count > 1 { return nil }
        }

        let identifierCandidates: [Int]
        if window.windowServerID == nil {
            identifierCandidates = Array(candidates.indices)
        } else {
            // Once the target had a WindowServer ID, another known ID is
            // contradictory evidence. Only an AX element without an ID may be
            // recovered through its stable identifier.
            identifierCandidates = candidates.indices.filter { candidates[$0].windowID == nil }
        }
        let identifierMatches = identifierCandidates.filter {
            !window.accessibilityIdentifier.isEmpty
                && candidates[$0].identifier == window.accessibilityIdentifier
        }
        if identifierMatches.count == 1 { return identifierMatches[0] }

        let scored = candidates.enumerated().compactMap { index, candidate -> (Int, Int)? in
            // A known, different ID is contradictory evidence, not a fallback.
            guard window.windowServerID == nil || candidate.windowID == nil else { return nil }
            guard let score = fallbackScore(candidateTitle: window.title, candidateBounds: window.bounds,
                candidateIsMinimized: window.isMinimized, candidateOrdinal: 0,
                accessibilityTitle: candidate.title, accessibilityBounds: candidate.bounds,
                accessibilityIsMinimized: candidate.isMinimized, accessibilityOrdinal: 0) else { return nil }
            return (index, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }),
              scored.filter({ $0.1 == best.1 }).count == 1 else { return nil }
        return best.0
    }
}

private final class SkyLightWindowActivator: @unchecked Sendable {
    static let shared = SkyLightWindowActivator()

    private typealias GetProcessForPIDFunction = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
    private typealias SetFrontProcessWithOptionsFunction = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Int32

    private let getProcessForPID: GetProcessForPIDFunction?
    private let setFrontProcessWithOptions: SetFrontProcessWithOptionsFunction?

    private init() {
        let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY | RTLD_LOCAL)
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        getProcessForPID = hiServices
            .flatMap { dlsym($0, "GetProcessForPID") }
            .map { unsafeBitCast($0, to: GetProcessForPIDFunction.self) }
        setFrontProcessWithOptions = skyLight
            .flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") ?? dlsym($0, "SLPSSetFrontProcessWithOptions") }
            .map { unsafeBitCast($0, to: SetFrontProcessWithOptionsFunction.self) }
    }

    func activateWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let getProcessForPID,
              let setFrontProcessWithOptions else { return false }
        var psn: (UInt32, UInt32) = (0, 0)
        return withUnsafeMutableBytes(of: &psn) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  getProcessForPID(pid, baseAddress) == noErr else { return false }
            // 0x200 == kCPSUserGenerated: switches active Space to windowID's Space without moving any window.
            return setFrontProcessWithOptions(baseAddress, windowID, 0x200) == 0
        }
    }
}

@MainActor
private final class AXWindowActivationDriver: WindowActivationDriving,
    ApplicationOnlyActivationDriving, ProcessValidatingActivationDriving {
    private let application: AXUIElement
    private let ownerApplication: NSRunningApplication?
    private let activationApplication: NSRunningApplication?
    private var target: AXUIElement?
    private var deadline = TimeInterval.greatestFiniteMagnitude
    private var usedSkyLightActivation = false
    private let selected: WindowInfo

    init(window: WindowInfo) {
        selected = window
        application = AXUIElementCreateApplication(window.ownerPID)
        ownerApplication = NSRunningApplication(processIdentifier: window.ownerPID)
        activationApplication = NSRunningApplication(processIdentifier: window.activationPID)
    }
    func setDeadline(_ deadline: TimeInterval) { self.deadline = deadline }
    private func budget(_ element: AXUIElement) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(0.04, remaining)))
        return true
    }
    private func read(_ name: String, from element: AXUIElement) -> (AXError, CFTypeRef?) {
        guard budget(element) else { return (.cannotComplete, nil) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }
    private func write(_ name: String, value: CFTypeRef, to element: AXUIElement) {
        guard budget(element) else { return }
        _ = AXUIElementSetAttributeValue(element, name as CFString, value)
    }
    func validateProcess(_ window: WindowInfo) -> Bool {
        guard let ownerApplication, !ownerApplication.isTerminated,
              let activationApplication, !activationApplication.isTerminated else { return false }
        return WindowMatchingPolicy.representsSameProcess(expectedPID: window.ownerPID,
            expectedBundleIdentifier: "", expectedLaunchDate: window.processLaunchDate,
            actualPID: ownerApplication.processIdentifier, actualBundleIdentifier: ownerApplication.bundleIdentifier,
            actualLaunchDate: ownerApplication.launchDate)
            && WindowMatchingPolicy.representsSameProcess(expectedPID: window.activationPID,
                expectedBundleIdentifier: window.bundleIdentifier, expectedLaunchDate: window.activationProcessLaunchDate,
                actualPID: activationApplication.processIdentifier, actualBundleIdentifier: activationApplication.bundleIdentifier,
                actualLaunchDate: activationApplication.launchDate)
    }
    private func surfaceExists(_ id: CGWindowID) -> Bool? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return nil }
        return rows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
            && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == selected.ownerPID }
    }
    private func isSurfaceOnScreen(_ id: CGWindowID) -> Bool? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let row = rows.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
                      && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == selected.ownerPID
              }) else { return nil }
        return (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    }
    private func hasCompetingWindowSurface(excluding id: CGWindowID) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        return rows.contains { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == selected.ownerPID,
                  let otherID = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  otherID != 0, otherID != id,
                  otherID != selected.windowServerID,
                  otherID != selected.presentationWindowID,
                  ((row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) == 0,
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let boundsDict = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 120, bounds.height >= 80
            else { return false }
            return true
        }
    }
    func validateApplicationTarget(_ window: WindowInfo) -> Bool {
        guard validateProcess(window), let id = window.presentationWindowID ?? window.windowServerID else { return false }
        return surfaceExists(id) == true
    }
    private func accept(_ element: AXUIElement, id: CGWindowID?) -> WindowResolution {
        guard budget(element) else { return .temporarilyUnavailable }
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(element, &pid)
        guard pidError == .success, pid == selected.ownerPID else {
            return pidError == .cannotComplete ? .temporarilyUnavailable : .absent
        }
        let (error, role) = read(kAXRoleAttribute, from: element)
        if error == .cannotComplete { return .temporarilyUnavailable }
        guard error == .success, role as? String == kAXWindowRole || role as? String == kAXSheetRole else { return .absent }
        if let id {
            guard budget(element) else { return .temporarilyUnavailable }
            guard AccessibilityWindowIdentityResolver.windowID(for: element) == id else { return .absent }
            AXWindowReferenceCache.shared.store(element, ownerPID: selected.ownerPID,
                launchDate: selected.processLaunchDate, windowID: id)
        }
        target = element
        return .found
    }
    func resolve(_ window: WindowInfo) -> WindowResolution {
        target = nil
        guard validateProcess(window) else { return .absent }
        let id = window.presentationWindowID ?? window.windowServerID
        if let id {
            // A snapshot is intentionally reused for up to three seconds.
            // In that interval Command-M can remove a normal-looking CG
            // surface before the next reconciliation marks it minimized.
            // Never use that stale CG observation to bypass AX: AX remains
            // authoritative for both an already-minimized window and a
            // window that has just been minimized.
            if let cached = AXWindowReferenceCache.shared.element(ownerPID: window.ownerPID,
                launchDate: window.processLaunchDate, windowID: id) {
                let result = accept(cached, id: id)
                if result != .absent { return result }
                AXWindowReferenceCache.shared.remove(ownerPID: window.ownerPID, windowID: id)
            }
        }
        let (error, value) = read(kAXWindowsAttribute, from: application)
        guard error == .success, let primaryElements = value as? [AXUIElement] else {
            return error == .invalidUIElement ? .absent : .temporarilyUnavailable
        }
        var elements = primaryElements
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            let (extraStatus, extraValue) = read(attribute, from: application)
            if extraStatus == .success, let extraValue, CFGetTypeID(extraValue) == AXUIElementGetTypeID() {
                let extra = extraValue as! AXUIElement
                if !elements.contains(where: { CFEqual($0, extra) }) {
                    elements.append(extra)
                }
            }
        }
        var identifierMatches: [AXUIElement] = []
        var dialogMatches: [AXUIElement] = []
        for element in elements {
            guard budget(element) else { return .temporarilyUnavailable }
            let elementWindowID = AccessibilityWindowIdentityResolver.windowID(for: element)
            if let id, elementWindowID == id {
                return accept(element, id: id)
            }
            if window.presentationWindowID != nil, elementWindowID == nil {
                let (subroleStatus, subroleValue) = read(kAXSubroleAttribute, from: element)
                if subroleStatus == .cannotComplete { return .temporarilyUnavailable }
                if subroleValue as? String == kAXDialogSubrole as String {
                    dialogMatches.append(element)
                }
            }
            if id == nil, !window.accessibilityIdentifier.isEmpty {
                let (status, identifier) = read(kAXIdentifierAttribute, from: element)
                if status == .cannotComplete { return .temporarilyUnavailable }
                if identifier as? String == window.accessibilityIdentifier { identifierMatches.append(element) }
            }
        }
        if dialogMatches.count == 1, let onlyDialog = dialogMatches.first {
            return accept(onlyDialog, id: nil)
        }
        if identifierMatches.count > 1 { return .ambiguous }
        if let only = identifierMatches.first { return accept(only, id: nil) }
        // A known live CG surface may be omitted by an app's off-Space AX tree,
        // whereas a vanished CG surface after a clean AX read proves closure.
        if let id {
            guard surfaceExists(id) != false else { return .absent }
            if surfaceExists(id) == true,
               isSurfaceOnScreen(id) == false,
               elements.isEmpty,
               !hasCompetingWindowSurface(excluding: id) {
                return .omittedOffSpace
            }
            return .temporarilyUnavailable
        }
        return window.accessibilityIdentifier.isEmpty ? .ambiguous : .absent
    }
    func restore() {
        guard selected.presentationWindowID == nil, let target else { return }
        write(kAXMinimizedAttribute, value: kCFBooleanFalse, to: target)
    }
    func focus() {
        guard let target else { return }
        write(kAXMainAttribute, value: kCFBooleanTrue, to: target)
        write(kAXFocusedWindowAttribute, value: target, to: application)
        if budget(target) { _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString) }
    }
    func activateApplication() {
        guard ProcessInfo.processInfo.systemUptime < deadline, let app = activationApplication else { return }
        let id = selected.presentationWindowID ?? selected.windowServerID
        if target == nil, let id,
           let cached = AXWindowReferenceCache.shared.element(ownerPID: selected.ownerPID,
               launchDate: selected.processLaunchDate, windowID: id),
           accept(cached, id: id) == .found {
            focus()
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        if app.isHidden { app.unhide() }
        if NSApp.isActive { NSApp.yieldActivation(to: app) }
        let isOffScreenSurface = id.map { !isMinimized && surfaceExists($0) == true && isSurfaceOnScreen($0) == false } ?? false
        if !usedSkyLightActivation, isOffScreenSurface, let id,
           SkyLightWindowActivator.shared.activateWindow(pid: app.processIdentifier, windowID: id) {
            usedSkyLightActivation = true
        }
        _ = app.activate(options: NSApplication.ActivationOptions(rawValue: 1 << 1))
        if target != nil {
            focus()
        }
    }
    func confirmation(of window: WindowInfo) -> WindowActivationConfirmation {
        guard validateProcess(window) else { return .missing }
        let id = window.presentationWindowID ?? window.windowServerID
        // A missing CG surface is conclusive immediately when no AX target
        // exists, and after AX target invalidation otherwise (preserving
        // Command-M recovery when a window was just minimized).
        if let id, surfaceExists(id) == false {
            guard let target else { return .missing }
            switch accept(target, id: id) {
            case .absent, .ambiguous: return .missing
            case .found, .temporarilyUnavailable, .omittedOffSpace: break
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.activationPID else { return .pending }
        let (error, focused) = read(kAXFocusedWindowAttribute, from: application)
        if error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = focused as! AXUIElement
            if let id {
                guard budget(element) else { return .pending }
                let observedID = AccessibilityWindowIdentityResolver.windowID(for: element)
                TaberDiagnostics.record("focusObserved", fields: ["target": TaberDiagnostics.identity(window),
                    "focusedWindowID": observedID.map(Int.init) ?? 0, "focusedPID": window.ownerPID])
                if observedID == id { return .confirmed }
                if let hostID = window.windowServerID, observedID == hostID,
                   window.presentationWindowID != nil, isSurfaceOnScreen(id) == true {
                    return .confirmed
                }
                if observedID == nil, let target, CFEqual(element, target) { return .confirmed }
            } else if let target, CFEqual(element, target) { return .confirmed }
            if window.activationMode == .activateApplication {
                if let id {
                    return isSurfaceOnScreen(id) == true ? .applicationActivated : .pending
                }
                return .applicationActivated
            }
            // A different known focused window is contrary evidence, even if selected is on-screen.
            return .pending
        }
        if window.activationMode == .activateApplication, error != .cannotComplete {
            if let id {
                return isSurfaceOnScreen(id) == true ? .applicationActivated : .pending
            }
            return .applicationActivated
        }
        return .pending
    }
    var isMinimized: Bool {
        guard let target else { return false }
        return (read(kAXMinimizedAttribute, from: target).1 as? NSNumber)?.boolValue ?? false
    }
}

@MainActor
enum TaberDiagnostics {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--diagnostics") || UserDefaults.standard.bool(forKey: "diagnosticsEnabled") }
    static let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("Taber-Diagnostics-\(ProcessInfo.processInfo.processIdentifier).jsonl")
    static func record(_ event: String, fields: [String: Any]) {
        guard enabled else { return }
        var record = fields; record["event"] = event; record["uptime"] = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: outputURL.path) {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: outputURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10]))
    }
    private static var opaqueIdentities: [WindowIdentity: Int] = [:]
    static func identity(_ window: WindowInfo) -> String {
        let birth = window.processLaunchDate?.timeIntervalSince1970 ?? 0
        if let id = window.windowServerID { return "cg:\(window.ownerPID):\(birth):\(id)" }
        if opaqueIdentities[window.id] == nil { opaqueIdentities[window.id] = opaqueIdentities.count + 1 }
        return "ax:\(window.ownerPID):\(birth):\(opaqueIdentities[window.id]!)"
    }
    static func recordActivation(_ window: WindowInfo, result: WindowActivationResult, started: TimeInterval) {
        record("activation", fields: ["target": identity(window),
            "presentationWindowID": window.presentationWindowID.map(Int.init) ?? 0,
            "activationPID": window.activationPID,
            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "outcome": String(describing: result.outcome), "strategy": result.strategy.rawValue,
            "elapsedMs": (ProcessInfo.processInfo.systemUptime - started) * 1000])
    }
}
