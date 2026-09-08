import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let shortcutEnabled = "shortcutEnabled"
        static let includeUtilityWindows = "includeUtilityWindows"
        static let switcherStyle = "switcherStyle"
        static let switcherSize = "switcherSize"
        static let appTheme = "appTheme"
        static let searchShortcut = "searchShortcut"
        static let keepSearchOpen = "keepSearchOpen"
        static let transparencyEnabled = "transparencyEnabled"
    }

    private let defaults: UserDefaults

    @Published var settingsSection: String {
        didSet { defaults.set(settingsSection, forKey: "settingsSection") }
    }

    @Published var shortcutEnabled: Bool {
        didSet { defaults.set(shortcutEnabled, forKey: Keys.shortcutEnabled) }
    }

    @Published var includeUtilityWindows: Bool {
        didSet { defaults.set(includeUtilityWindows, forKey: Keys.includeUtilityWindows) }
    }

    @Published var switcherStyle: SwitcherStyle {
        didSet { defaults.set(switcherStyle.rawValue, forKey: Keys.switcherStyle) }
    }

    @Published var switcherSize: SwitcherSize {
        didSet { defaults.set(switcherSize.rawValue, forKey: Keys.switcherSize) }
    }

    @Published var appTheme: AppTheme {
        didSet { defaults.set(appTheme.rawValue, forKey: Keys.appTheme) }
    }

    @Published var searchShortcut: SearchShortcut {
        didSet { defaults.set(searchShortcut.rawValue, forKey: Keys.searchShortcut) }
    }

    @Published var keepSearchOpen: Bool {
        didSet { defaults.set(keepSearchOpen, forKey: Keys.keepSearchOpen) }
    }

    @Published var transparencyEnabled: Bool {
        didSet { defaults.set(transparencyEnabled, forKey: Keys.transparencyEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settingsSection = defaults.string(forKey: "settingsSection") ?? "appearance"
        shortcutEnabled = defaults.object(forKey: Keys.shortcutEnabled) as? Bool ?? true
        includeUtilityWindows = defaults.object(forKey: Keys.includeUtilityWindows) as? Bool ?? false
        keepSearchOpen = defaults.object(forKey: Keys.keepSearchOpen) as? Bool ?? true
        transparencyEnabled = defaults.object(forKey: Keys.transparencyEnabled) as? Bool ?? false

        if let rawValue = defaults.string(forKey: Keys.switcherStyle),
           let style = SwitcherStyle(rawValue: rawValue) {
            switcherStyle = style
        } else {
            switcherStyle = .preview
        }

        if let rawValue = defaults.string(forKey: Keys.switcherSize),
           let size = SwitcherSize(rawValue: rawValue) {
            switcherSize = size
        } else {
            switcherSize = .medium
        }

        if let rawValue = defaults.string(forKey: Keys.appTheme),
           let theme = AppTheme(rawValue: rawValue) {
            appTheme = theme
        } else {
            appTheme = .original
        }

        if let rawValue = defaults.string(forKey: Keys.searchShortcut),
           let shortcut = SearchShortcut(rawValue: rawValue) {
            searchShortcut = shortcut
        } else {
            searchShortcut = .doubleShift
        }
    }
}
