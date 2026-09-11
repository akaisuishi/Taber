import AppKit

enum WindowEvidence: Sendable { case windowServer, accessibility, both }
enum WindowEligibilityReason: String, Sendable {
    case standardWindow, dialog, utility, customSurface, nestedRenderer
    case systemShell, noUserSurface, utilityDisabled, implausibleGeometry
}
struct WindowEligibilityDecision: Sendable { let isEligible: Bool; let reason: WindowEligibilityReason }

struct WindowEligibilityContext {
    let bundleIdentifier: String
    let activationPolicy: NSApplication.ActivationPolicy
    let title: String
    let bounds: CGRect
    let layer: Int
    let alpha: CGFloat
    let isOnScreen: Bool
    let isHelperProcess: Bool
    let evidence: WindowEvidence
    let accessibilitySubrole: String

    init(bundleIdentifier: String, activationPolicy: NSApplication.ActivationPolicy, title: String,
         bounds: CGRect, layer: Int, alpha: CGFloat, isOnScreen: Bool, isHelperProcess: Bool,
         evidence: WindowEvidence = .windowServer, accessibilitySubrole: String = "") {
        self.bundleIdentifier = bundleIdentifier; self.activationPolicy = activationPolicy; self.title = title
        self.bounds = bounds; self.layer = layer; self.alpha = alpha; self.isOnScreen = isOnScreen
        self.isHelperProcess = isHelperProcess; self.evidence = evidence; self.accessibilitySubrole = accessibilitySubrole
    }
}

enum WindowEligibilityPolicy {
    private static let systemShellBundleIdentifiers: Set<String> = [
        "com.apple.Spotlight", "com.apple.controlcenter", "com.apple.dock",
        "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager",
        "com.apple.TextInputSwitcher", "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.AccessibilityVisualsAgent"
    ]

    static func isUserAccessibilitySurface(bundleIdentifier: String, role: String, subrole: String) -> Bool {
        guard role.isEmpty || role == kAXWindowRole as String || role == kAXSheetRole as String else { return false }
        if bundleIdentifier == "com.apple.finder" {
            return subrole == kAXStandardWindowSubrole as String
                || subrole == kAXDialogSubrole as String || role == kAXSheetRole as String
        }
        return true
    }

    static func evaluate(_ context: WindowEligibilityContext, includeUtilityWindows: Bool) -> WindowEligibilityDecision {
        if systemShellBundleIdentifiers.contains(context.bundleIdentifier) {
            return .init(isEligible: false, reason: .systemShell)
        }
        let isUtility = context.accessibilitySubrole == kAXFloatingWindowSubrole as String
            || context.accessibilitySubrole == kAXSystemFloatingWindowSubrole as String
        if isUtility && !includeUtilityWindows { return .init(isEligible: false, reason: .utilityDisabled) }
        let hasAX = context.evidence == .accessibility || context.evidence == .both
        let plausibleSize = context.bounds.width >= 80 && context.bounds.height >= 50
        guard plausibleSize else { return .init(isEligible: false, reason: .implausibleGeometry) }

        // AX window roles are direct evidence. CG-only custom renderers are
        // accepted when they expose a substantial user surface, even from an
        // accessory/prohibited nested helper (common in games/Electron).
        if hasAX {
            if isUtility { return .init(isEligible: true, reason: .utility) }
            if context.accessibilitySubrole == kAXDialogSubrole as String { return .init(isEligible: true, reason: .dialog) }
            return .init(isEligible: true, reason: context.isHelperProcess ? .nestedRenderer : .standardWindow)
        }
        let named = !context.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let credibleCG = context.layer == 0 && (context.alpha > 0.01 || !context.isOnScreen)
            && (context.isOnScreen || named || context.bounds.width >= 640 || context.bounds.height >= 480)
        guard credibleCG else { return .init(isEligible: false, reason: .noUserSurface) }
        switch context.activationPolicy {
        case .regular: return .init(isEligible: true, reason: context.isHelperProcess ? .nestedRenderer : .customSurface)
        case .accessory, .prohibited:
            guard context.isOnScreen && (named || context.bounds.width >= 640) else {
                return .init(isEligible: false, reason: .noUserSurface)
            }
            return .init(isEligible: true, reason: context.isHelperProcess ? .nestedRenderer : .customSurface)
        @unknown default: return .init(isEligible: false, reason: .noUserSurface)
        }
    }

    static func allows(_ context: WindowEligibilityContext, includeUtilityWindows: Bool) -> Bool {
        evaluate(context, includeUtilityWindows: includeUtilityWindows).isEligible
    }
}
