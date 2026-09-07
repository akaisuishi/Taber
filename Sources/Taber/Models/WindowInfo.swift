import AppKit

enum WindowSpaceState {
    case current
    case another
    case minimized
    case fullScreen

    var title: String {
        switch self {
        case .current: "Space atual"
        case .another: "Outro Space"
        case .minimized: "Minimizada"
        case .fullScreen: "Tela Cheia"
        }
    }

    var symbolName: String {
        switch self {
        case .current: "rectangle.on.rectangle"
        case .another: "squares.leading.rectangle"
        case .minimized: "minus.circle.fill"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        }
    }
}

enum WindowActivationMode {
    case raiseWindow
    case activateApplication
}

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let ownerPID: pid_t
    let processLaunchDate: Date?
    let bundleIdentifier: String
    let applicationName: String
    let title: String
    let bounds: CGRect
    let isOnScreen: Bool
    let isMinimized: Bool
    let isFullScreen: Bool
    let activationMode: WindowActivationMode
    let spaceIdentifier: UInt64?
    let spaceNumber: Int?
    let spaceLocations: [SpaceLocation]
    let isOnAllDesktops: Bool
    let screenName: String
    let icon: NSImage?
    let accessibilityIdentifier: String
    let accessibilityOrdinal: Int?
    let isAccessibilityFocused: Bool
    let titleOccurrence: Int?
    let titleOccurrenceCount: Int

    init(
        id: CGWindowID,
        ownerPID: pid_t,
        bundleIdentifier: String,
        applicationName: String,
        title: String,
        bounds: CGRect,
        isOnScreen: Bool,
        isMinimized: Bool,
        isFullScreen: Bool = false,
        activationMode: WindowActivationMode = .raiseWindow,
        spaceIdentifier: UInt64? = nil,
        spaceNumber: Int? = nil,
        screenName: String = "",
        icon: NSImage?,
        accessibilityIdentifier: String = "",
        accessibilityOrdinal: Int? = nil,
        isAccessibilityFocused: Bool = false,
        titleOccurrence: Int? = nil,
        titleOccurrenceCount: Int = 1,
        processLaunchDate: Date? = nil,
        spaceLocations: [SpaceLocation] = [],
        isOnAllDesktops: Bool = false
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.processLaunchDate = processLaunchDate
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.activationMode = activationMode
        self.spaceIdentifier = spaceIdentifier
        self.spaceNumber = spaceNumber
        self.spaceLocations = spaceLocations
        self.isOnAllDesktops = isOnAllDesktops
        self.screenName = screenName
        self.icon = icon
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityOrdinal = accessibilityOrdinal
        self.isAccessibilityFocused = isAccessibilityFocused
        self.titleOccurrence = titleOccurrence
        self.titleOccurrenceCount = titleOccurrenceCount
    }

    var applicationIdentifier: String {
        bundleIdentifier.isEmpty ? "\(ownerPID)-\(applicationName)" : bundleIdentifier
    }

    var spaceState: WindowSpaceState {
        if isFullScreen { return .fullScreen }
        if isMinimized { return .minimized }
        return isOnScreen ? .current : .another
    }

    var spaceDescription: String {
        guard !screenName.isEmpty else { return spaceLabel }
        return "\(spaceLabel) · \(screenName)"
    }

    var spaceLabel: String {
        if isOnAllDesktops { return isMinimized ? "Todos os Desktops · Minimizada" : "Todos os Desktops" }
        if spaceLocations.count > 1 {
            let numbers = spaceLocations.compactMap(\.number).map(String.init).joined(separator: ", ")
            return numbers.isEmpty ? "Múltiplos Spaces" : "Spaces \(numbers)" + (isMinimized ? " · Minimizada" : "")
        }
        guard let spaceNumber else { return spaceState.title }
        return switch spaceState {
        case .current, .another: "Space \(spaceNumber)"
        case .minimized: "Space \(spaceNumber) · Minimizada"
        case .fullScreen: "Space \(spaceNumber) · Tela Cheia"
        }
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericWindowTitles = Set(["window", "janela"])
        let baseTitle = trimmedTitle.isEmpty
            || genericWindowTitles.contains(trimmedTitle.lowercased())
            ? applicationName
            : trimmedTitle
        guard titleOccurrenceCount > 1, let titleOccurrence else { return baseTitle }
        return "\(baseTitle) · Janela \(titleOccurrence)"
    }

    func withAccessibilityIdentity(
        identifier: String,
        ordinal: Int,
        accessibilityTitle: String,
        isMinimized: Bool,
        isFullScreen: Bool,
        isFocused: Bool,
        activationMode: WindowActivationMode? = nil
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: ownerPID,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            title: accessibilityTitle.isEmpty ? title : accessibilityTitle,
            bounds: bounds,
            isOnScreen: isOnScreen,
            isMinimized: isMinimized,
            isFullScreen: isFullScreen,
            activationMode: activationMode ?? self.activationMode,
            spaceIdentifier: spaceIdentifier,
            spaceNumber: spaceNumber,
            screenName: screenName,
            icon: icon,
            accessibilityIdentifier: identifier,
            accessibilityOrdinal: ordinal,
            isAccessibilityFocused: isFocused,
            titleOccurrence: titleOccurrence,
            titleOccurrenceCount: titleOccurrenceCount,
            processLaunchDate: processLaunchDate,
            spaceLocations: spaceLocations,
            isOnAllDesktops: isOnAllDesktops
        )
    }

    func withTitleOccurrence(_ occurrence: Int, count: Int) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: ownerPID,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            title: title,
            bounds: bounds,
            isOnScreen: isOnScreen,
            isMinimized: isMinimized,
            isFullScreen: isFullScreen,
            activationMode: activationMode,
            spaceIdentifier: spaceIdentifier,
            spaceNumber: spaceNumber,
            screenName: screenName,
            icon: icon,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityOrdinal: accessibilityOrdinal,
            isAccessibilityFocused: isAccessibilityFocused,
            titleOccurrence: occurrence,
            titleOccurrenceCount: count,
            processLaunchDate: processLaunchDate,
            spaceLocations: spaceLocations,
            isOnAllDesktops: isOnAllDesktops
        )
    }

    func withResolvedSpace(_ resolvedSpace: ResolvedWindowSpace?) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: ownerPID,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            title: title,
            bounds: bounds,
            isOnScreen: isOnScreen,
            isMinimized: isMinimized,
            isFullScreen: isFullScreen || (resolvedSpace?.isFullScreen ?? false),
            activationMode: activationMode,
            spaceIdentifier: resolvedSpace?.identifier,
            spaceNumber: resolvedSpace?.number,
            screenName: screenName,
            icon: icon,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityOrdinal: accessibilityOrdinal,
            isAccessibilityFocused: isAccessibilityFocused,
            titleOccurrence: titleOccurrence,
            titleOccurrenceCount: titleOccurrenceCount,
            processLaunchDate: processLaunchDate,
            spaceLocations: resolvedSpace?.locations ?? [],
            isOnAllDesktops: resolvedSpace?.isOnAllDesktops ?? false
        )
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.ownerPID == rhs.ownerPID && lhs.processLaunchDate == rhs.processLaunchDate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(ownerPID)
        hasher.combine(processLaunchDate)
    }
}
