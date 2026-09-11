import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import OSLog

@MainActor
protocol WindowActivationDriving {
    func resolve(_ window: WindowInfo) -> Bool
    func restore()
    func focus()
    func activateApplication()
    var isMinimized: Bool { get }
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
    case staleProcess
    case targetNotFound
    case localActivationFailed
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

/// Same activation sequence for live AX operations and deterministic drivers.
@MainActor
final class WindowActivationCoordinator {
    private var generation: UInt = 0
    private let driver: (WindowInfo) -> any WindowActivationDriving
    private let clock: any ActivationClock

    init(clock: any ActivationClock = SystemActivationClock(),
         driver: @escaping (WindowInfo) -> any WindowActivationDriving) {
        self.clock = clock
        self.driver = driver
    }

    @discardableResult
    func activate(_ window: WindowInfo) -> WindowActivationResult {
        cancelPending()
        let request = generation
        let target = driver(window)
        let strategy = WindowMatchingPolicy.activationStrategy(
            usesApplicationOnlyActivation: window.activationMode == .activateApplication,
            hasRegisteredLocalTarget: false
        )
        var steps: [WindowActivationStep] = []

        if let validating = target as? any ProcessValidatingActivationDriving {
            guard validating.validateProcess(window) else {
                return WindowActivationResult(strategy: strategy, outcome: .rejected(.staleProcess), steps: steps)
            }
            steps.append(.processValidated)
        }

        if strategy == .application {
            // Application-only targets deliberately do not require AX. Legacy
            // and fixture drivers still resolve so a closed target cannot
            // silently activate an arbitrary process.
            if let applicationTarget = target as? any ApplicationOnlyActivationDriving {
                guard applicationTarget.validateApplicationTarget(window) else {
                    return WindowActivationResult(strategy: strategy, outcome: .rejected(.staleProcess), steps: steps)
                }
            } else {
                guard target.resolve(window) else {
                    return WindowActivationResult(strategy: strategy, outcome: .rejected(.targetNotFound), steps: steps)
                }
                steps.append(.targetResolved)
            }
            target.activateApplication()
            steps.append(.applicationActivated)
            return WindowActivationResult(strategy: strategy, outcome: .activated, steps: steps)
        }

        guard target.resolve(window) else {
            return WindowActivationResult(strategy: strategy, outcome: .rejected(.targetNotFound), steps: steps)
        }
        steps.append(.targetResolved)
        target.restore()
        steps.append(.restored)
        target.activateApplication()
        steps.append(.applicationActivated)
        target.focus()
        steps.append(.focusedAndRaised)
        // Activating an app while leaving a fullscreen Space is asynchronous.
        // In that case the destination is reported as off-screen even though
        // it is not minimized, and the first AX raise can happen before the
        // Space transition completes. Repeat the identity-safe activation once
        // after the transition has had time to start.
        if window.isMinimized || !window.isOnScreen {
            steps.append(.retryScheduled)
            clock.schedule(after: .milliseconds(240)) { [weak self] in
                guard self?.generation == request,
                      target.resolve(window) else { return }
                if target.isMinimized {
                    target.restore()
                }
                target.activateApplication()
                target.focus()
            }
        }
        return WindowActivationResult(strategy: strategy, outcome: .activated, steps: steps)
    }

    func cancelPending() { generation &+= 1 }
}

@MainActor
enum AccessibilityService {
    typealias LocalWindowActivator = @MainActor () -> Bool

    private static let logger = Logger(subsystem: "com.taber.app", category: "activation")
    private static let coordinator = WindowActivationCoordinator { AXWindowActivationDriver(window: $0) }
    private static var localWindowActivators: [WindowInfo.ID: LocalWindowActivator] = [:]
    private(set) static var lastActivationResult: WindowActivationResult?
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
        let result: WindowActivationResult
        if let activateLocalWindow = localWindowActivators[window.id] {
            result = WindowActivationResult(
                strategy: .localWindow,
                outcome: activateLocalWindow() ? .activated : .rejected(.localActivationFailed),
                steps: []
            )
        } else {
            result = coordinator.activate(window)
        }
        lastActivationResult = result
        logger.notice(
            "Activation ownerPID=\(window.ownerPID) activationPID=\(window.activationPID) strategy=\(result.strategy.rawValue, privacy: .public) result=\(String(describing: result.outcome), privacy: .public) steps=\(result.steps.map(\.rawValue).joined(separator: ","), privacy: .public)"
        )
        return result
    }
    static func cancelPendingRestoration() { coordinator.cancelPending() }
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

@MainActor
private final class AXWindowActivationDriver: WindowActivationDriving,
    ApplicationOnlyActivationDriving, ProcessValidatingActivationDriving {
    private let application: AXUIElement
    private let ownerApplication: NSRunningApplication?
    private let activationApplication: NSRunningApplication?
    private var target: AXUIElement?

    init(window: WindowInfo) {
        application = AXUIElementCreateApplication(window.ownerPID)
        ownerApplication = NSRunningApplication(processIdentifier: window.ownerPID)
        activationApplication = NSRunningApplication(processIdentifier: window.activationPID)
        AXUIElementSetMessagingTimeout(application, 0.20)
    }

    func validateProcess(_ window: WindowInfo) -> Bool {
        guard let ownerApplication, !ownerApplication.isTerminated else { return false }
        return WindowMatchingPolicy.representsSameProcess(
            expectedPID: window.ownerPID,
            expectedBundleIdentifier: "",
            expectedLaunchDate: window.processLaunchDate,
            actualPID: ownerApplication.processIdentifier,
            actualBundleIdentifier: ownerApplication.bundleIdentifier,
            actualLaunchDate: ownerApplication.launchDate
        )
    }

    func validateApplicationTarget(_ window: WindowInfo) -> Bool {
        guard validateProcess(window),
              let activationApplication,
              !activationApplication.isTerminated else { return false }
        return WindowMatchingPolicy.representsSameProcess(
            expectedPID: window.activationPID,
            expectedBundleIdentifier: window.bundleIdentifier,
            expectedLaunchDate: window.activationProcessLaunchDate,
            actualPID: activationApplication.processIdentifier,
            actualBundleIdentifier: activationApplication.bundleIdentifier,
            actualLaunchDate: activationApplication.launchDate
        )
    }

    func resolve(_ window: WindowInfo) -> Bool {
        target = nil
        guard validateProcess(window) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return false }
        let candidates = elements.enumerated().map { ordinal, element in
            ActivationCandidate(windowID: AccessibilityWindowIdentityResolver.windowID(for: element),
                identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: element),
                title: stringAttribute(kAXTitleAttribute as CFString, from: element),
                bounds: bounds(of: element), isMinimized: boolAttribute(kAXMinimizedAttribute as CFString, from: element),
                ordinal: ordinal)
        }
        guard let index = WindowMatchingPolicy.activationCandidateIndex(for: window, in: candidates) else { return false }
        target = elements[index]
        return true
    }

    func restore() {
        guard let target else { return }
        _ = AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    func focus() {
        guard let target else { return }
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, target)
        _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }

    func activateApplication() { activationApplication?.activate(options: []) }
    var isMinimized: Bool {
        target.map { boolAttribute(kAXMinimizedAttribute as CFString, from: $0) } ?? false
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

}
