import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

@MainActor
enum AccessibilityService {
    private struct WindowCandidate {
        let element: AXUIElement
        let windowID: CGWindowID?
        let identifier: String
        let title: String
        let bounds: CGRect?
        let isMinimized: Bool
        let ordinal: Int
    }

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

    static func restoreAndRaise(window: WindowInfo) {
        let runningApplication = NSRunningApplication(processIdentifier: window.ownerPID)

        // Fullscreen de mídia em navegadores é apresentado por uma superfície
        // separada que não pertence a kAXWindows. Levantar a janela AX normal
        // encobre essa superfície; somente reativar o app preserva o vídeo.
        if window.activationMode == .activateApplication {
            runningApplication?.activate(options: [])
            return
        }

        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue)

        if result == .success, let windows = windowsValue as? [AXUIElement] {
            // Resolva o alvo antes de ativar o aplicativo. A ativação pode
            // reordenar kAXWindows e tornaria o ordinal menos confiável.
            let matchingWindow = bestMatchingWindow(in: windows, for: window)

            if let matchingWindow {
                let minimized = false
                let selected = true
                _ = AXUIElementSetAttributeValue(matchingWindow, kAXMinimizedAttribute as CFString, minimized as CFTypeRef)
                // Defina a janela-alvo no processo antes de ativá-lo. Chrome,
                // Finder e outros apps com várias janelas podem restaurar a
                // última janela ativa quando o processo é ativado primeiro.
                // Reafirmar o foco após a ativação cobre implementações AX que
                // só aceitam a alteração enquanto o aplicativo está ativo.
                _ = AXUIElementSetAttributeValue(
                    application,
                    kAXFocusedWindowAttribute as CFString,
                    matchingWindow
                )
                _ = AXUIElementSetAttributeValue(matchingWindow, kAXMainAttribute as CFString, selected as CFTypeRef)
                _ = AXUIElementSetAttributeValue(matchingWindow, kAXFocusedAttribute as CFString, selected as CFTypeRef)
                runningApplication?.activate(options: [])
                _ = AXUIElementSetAttributeValue(
                    application,
                    kAXFocusedWindowAttribute as CFString,
                    matchingWindow
                )
                _ = AXUIElementPerformAction(matchingWindow, kAXRaiseAction as CFString)
                return
            }
        }

        runningApplication?.activate(options: [])
    }

    private static func bestMatchingWindow(
        in elements: [AXUIElement],
        for window: WindowInfo
    ) -> AXUIElement? {
        let candidates = elements.enumerated().map { ordinal, element in
            WindowCandidate(
                element: element,
                windowID: AccessibilityWindowIdentityResolver.windowID(for: element),
                identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: element),
                title: stringAttribute(kAXTitleAttribute as CFString, from: element),
                bounds: bounds(of: element),
                isMinimized: boolAttribute(kAXMinimizedAttribute as CFString, from: element),
                ordinal: ordinal
            )
        }

        if let exactWindow = candidates.first(where: { $0.windowID == window.id }) {
            return exactWindow.element
        }

        if let uniqueIdentifierIndex = WindowMatchingPolicy.uniqueIdentifierIndex(
            targetIdentifier: window.accessibilityIdentifier,
            candidateIdentifiers: candidates.map(\.identifier)
        ) {
            return candidates[uniqueIdentifierIndex].element
        }

        let scored = candidates.compactMap { candidate -> (WindowCandidate, Int)? in
            guard let score = WindowMatchingPolicy.fallbackScore(
                candidateTitle: window.title,
                candidateBounds: window.bounds,
                candidateIsMinimized: window.isMinimized,
                candidateOrdinal: window.accessibilityOrdinal ?? Int.max / 2,
                accessibilityTitle: candidate.title,
                accessibilityBounds: candidate.bounds,
                accessibilityIsMinimized: candidate.isMinimized,
                accessibilityOrdinal: candidate.ordinal
            ) else { return nil }
            return (candidate, score)
        }

        return scored.max(by: { $0.1 < $1.1 })?.0.element
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func bounds(of element: AXUIElement) -> CGRect? {
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
