import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

@MainActor
protocol WindowActivationDriving {
    func resolve(_ window: WindowInfo) -> Bool
    func restore()
    func focus()
    func activateApplication()
    var isMinimized: Bool { get }
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

    func activate(_ window: WindowInfo) {
        cancelPending()
        let request = generation
        let target = driver(window)
        // Resolve even presentation hosts: a closed/restarted app must not
        // reactivate whichever unrelated window happens to remain.
        guard target.resolve(window) else { return }
        if WindowMatchingPolicy.shouldActivateApplicationWithoutRestoring(
            usesApplicationOnlyActivation: window.activationMode == .activateApplication,
            isMinimized: window.isMinimized) {
            target.activateApplication()
            return
        }
        target.restore()
        target.focus()
        target.activateApplication()
        target.restore()
        target.focus()
        if window.isMinimized {
            clock.schedule(after: .milliseconds(100)) { [weak self] in
                guard self?.generation == request,
                      target.resolve(window), target.isMinimized else { return }
                target.restore()
                target.activateApplication()
                target.focus()
            }
        }
    }

    func cancelPending() { generation &+= 1 }
}

@MainActor
enum AccessibilityService {
    private static let coordinator = WindowActivationCoordinator { AXWindowActivationDriver(window: $0) }
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


    static func restoreAndRaise(window: WindowInfo) { coordinator.activate(window) }
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
        if let exact = candidates.firstIndex(where: { $0.windowID == window.id }) { return exact }
        if let unique = uniqueIdentifierIndex(targetIdentifier: window.accessibilityIdentifier,
                                               candidateIdentifiers: candidates.map(\.identifier)),
           candidates[unique].windowID == nil { return unique }
        let scored = candidates.enumerated().compactMap { index, candidate -> (Int, Int)? in
            // A known, different ID is contradictory evidence, not a fallback.
            guard candidate.windowID == nil else { return nil }
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
private final class AXWindowActivationDriver: WindowActivationDriving {
    private let application: AXUIElement
    private let running: NSRunningApplication?
    private var target: AXUIElement?

    init(window: WindowInfo) {
        application = AXUIElementCreateApplication(window.ownerPID)
        running = NSRunningApplication(processIdentifier: window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.20)
    }

    func resolve(_ window: WindowInfo) -> Bool {
        target = nil
        guard let running, !running.isTerminated,
              (running.bundleIdentifier ?? "") == window.bundleIdentifier,
              window.processLaunchDate == nil || running.launchDate == window.processLaunchDate else { return false }
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

    func activateApplication() { running?.activate(options: []) }
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
