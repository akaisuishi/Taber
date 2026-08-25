import AppKit

struct WindowEligibilityContext {
    let bundleIdentifier: String
    let activationPolicy: NSApplication.ActivationPolicy
    let title: String
    let bounds: CGRect
    let layer: Int
    let alpha: CGFloat
    let isOnScreen: Bool
    let isHelperProcess: Bool
}

enum WindowEligibilityPolicy {
    private static let systemShellBundleIdentifiers: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.controlcenter",
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.apple.TextInputSwitcher",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.AccessibilityVisualsAgent"
    ]

    static func allows(_ context: WindowEligibilityContext, includeUtilityWindows: Bool) -> Bool {
        guard context.layer == 0,
              context.alpha > 0.01,
              context.bounds.width >= 160,
              context.bounds.height >= 100,
              !context.isHelperProcess,
              !systemShellBundleIdentifiers.contains(context.bundleIdentifier)
        else { return false }

        switch context.activationPolicy {
        case .regular:
            // Janelas normais continuam elegíveis fora do Space atual ou
            // minimizadas; nesses casos isOnScreen será false.
            return true

        case .accessory:
            // Agentes de menu como Google Drive mantêm janelas ocultas no
            // WindowServer. Um acessório só entra quando expõe um painel real,
            // visível e nomeado no momento da troca.
            return includeUtilityWindows
                && context.isOnScreen
                && !context.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .prohibited:
            return false

        @unknown default:
            return false
        }
    }
}
