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
    func confirmation(of window: WindowInfo) -> WindowActivationConfirmation
}

enum WindowActivationConfirmation { case pending, confirmed, missing }

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
    private let now: () -> TimeInterval
    private var pendingResult: WindowActivationResult?
    var onResult: ((WindowActivationResult) -> Void)?

    init(clock: any ActivationClock = SystemActivationClock(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         driver: @escaping (WindowInfo) -> any WindowActivationDriving) {
        self.clock = clock
        self.now = now
        self.driver = driver
    }

    @discardableResult
    func activate(_ window: WindowInfo) -> WindowActivationResult {
        cancelPending()
        let request = generation
        let deadline = now() + 2
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
            return confirm(window, target: target, strategy: strategy, steps: steps,
                           request: request, deadline: deadline, remaining: 10)
        }

        guard target.resolve(window) else {
            return WindowActivationResult(strategy: strategy, outcome: .rejected(.targetNotFound), steps: steps)
        }
        steps.append(.targetResolved)
        if target.isMinimized {
            target.restore()
            steps.append(.restored)
        }
        target.activateApplication()
        steps.append(.applicationActivated)
        target.focus()
        steps.append(.focusedAndRaised)
        return confirm(window, target: target, strategy: strategy, steps: steps,
                       request: request, deadline: deadline, remaining: 10)
    }

    private func confirm(_ window: WindowInfo, target: any WindowActivationDriving,
                         strategy: WindowMatchingPolicy.ActivationStrategy,
                         steps: [WindowActivationStep], request: UInt,
                         deadline: TimeInterval, remaining: Int) -> WindowActivationResult {
        let state = target.confirmation(of: window)
        let outcome: WindowActivationResult.Outcome
        switch state {
        case .confirmed: outcome = .activated
        case .missing: outcome = .rejected(.targetNotFound)
        case .pending: outcome = remaining == 0 || now() >= deadline ? .rejected(.timedOut) : .requested
        }
        var steps = steps
        if outcome == .requested && !steps.contains(.retryScheduled) { steps.append(.retryScheduled) }
        let result = WindowActivationResult(strategy: strategy, outcome: outcome, steps: steps)
        pendingResult = outcome == .requested ? result : nil
        onResult?(result)
        guard outcome == .requested else { return result }
        clock.schedule(after: .milliseconds(200)) { [weak self] in
            guard let self, self.generation == request else { return }
            // Observe before retrying: a completed transition must not steal focus again.
            if target.confirmation(of: window) == .pending && self.now() < deadline && remaining > 1 {
                if strategy == .application {
                    if let validator = target as? any ApplicationOnlyActivationDriving,
                       validator.validateApplicationTarget(window) {
                        target.activateApplication()
                    }
                } else if target.resolve(window) {
                    if target.isMinimized { target.restore() }
                    target.activateApplication()
                    target.focus()
                }
            }
            _ = self.confirm(window, target: target, strategy: strategy, steps: steps,
                             request: request, deadline: deadline, remaining: remaining - 1)
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
        coordinator.onResult = { result in
            lastActivationResult = result
            logger.notice("Activation progress=\(String(describing: result.outcome), privacy: .public)")
        }
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
    private var resolutionIncomplete = false
    private var target: AXUIElement?
    private let presentationWindowID: CGWindowID?

    init(window: WindowInfo) {
        presentationWindowID = window.presentationWindowID
        application = AXUIElementCreateApplication(window.ownerPID)
        ownerApplication = NSRunningApplication(processIdentifier: window.ownerPID)
        activationApplication = NSRunningApplication(processIdentifier: window.activationPID)
        AXUIElementSetMessagingTimeout(application, 0.04)
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
        guard surfaceExists(window.presentationWindowID ?? window.windowServerID, ownerPID: window.ownerPID) else { return false }
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
        resolutionIncomplete = false
        guard validateProcess(window) else { return false }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let elements = value as? [AXUIElement] else {
            resolutionIncomplete = status == .cannotComplete
            return false
        }
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

    func activateApplication() {
        activationApplication?.activate(options: [])
        // Raise the player itself when it exposes AX, never its normal host window.
        if let presentationWindowID {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
               let elements = value as? [AXUIElement],
               let player = elements.first(where: { AccessibilityWindowIdentityResolver.windowID(for: $0) == presentationWindowID }) {
                _ = AXUIElementPerformAction(player, kAXRaiseAction as CFString)
            }
        }
    }

    private func surfaceExists(_ id: CGWindowID?, ownerPID: pid_t) -> Bool {
        guard let id else { return false }
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
            && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID }
    }

    func confirmation(of window: WindowInfo) -> WindowActivationConfirmation {
        guard validateProcess(window) else { return .missing }
        if window.activationMode == .activateApplication {
            guard validateApplicationTarget(window) else { return .missing }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.activationPID else { return .pending }
            let id = window.presentationWindowID ?? window.windowServerID
            guard let id, let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return .pending }
            return rows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id } ? .confirmed : .pending
        }
        guard resolve(window), let target else { return resolutionIncomplete ? .pending : .missing }
        guard !isMinimized,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.activationPID else { return .pending }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, target) else { return .pending }
        if let id = window.windowServerID,
           let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
           !rows.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) { return .pending }
        return .confirmed
    }
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
