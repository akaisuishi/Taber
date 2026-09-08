import AppKit

enum WindowIdentity: Hashable, Sendable, CustomStringConvertible {
    case windowServer(ownerPID: pid_t, launchDate: Date?, id: CGWindowID)
    case accessibility(ownerPID: pid_t, launchDate: Date?, identifier: String, fallback: AccessibilityWindowFallback)
    case application(ownerPID: pid_t, launchDate: Date?, bundleIdentifier: String)
    var windowServerID: CGWindowID? { guard case let .windowServer(_, _, id) = self else { return nil }; return id }
    var description: String {
        switch self {
        case let .windowServer(pid, _, id): "cg:\(pid):\(id)"
        case let .accessibility(pid, _, identifier, fallback): identifier.isEmpty ? "ax:\(pid):\(fallback)" : "ax:\(pid):\(identifier)"
        case let .application(pid, _, bundle): "app:\(pid):\(bundle)"
        }
    }
}

struct AccessibilityWindowFallback: Hashable, Sendable, CustomStringConvertible {
    let document: String, title: String
    let x: Int, y: Int, width: Int, height: Int, ordinal: Int
    init(document: String, title: String, bounds: CGRect?, ordinal: Int) {
        func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        func quantized(_ value: CGFloat?) -> Int { guard let value, value.isFinite else { return Int.min }; return Int((value / 4).rounded()) }
        self.document = normalized(document); self.title = normalized(title)
        x = quantized(bounds?.minX); y = quantized(bounds?.minY); width = quantized(bounds?.width); height = quantized(bounds?.height); self.ordinal = ordinal
    }
    var description: String { "\(document)|\(title)|\(x),\(y),\(width),\(height)|\(ordinal)" }
}

enum WindowSpaceState {
    case current, another, minimized, fullScreen
    var title: String { switch self { case .current: "Space atual"; case .another: "Outro Space"; case .minimized: "Minimizada"; case .fullScreen: "Tela Cheia" } }
    var symbolName: String { switch self { case .current: "rectangle.on.rectangle"; case .another: "squares.leading.rectangle"; case .minimized: "minus.circle.fill"; case .fullScreen: "arrow.up.left.and.arrow.down.right" } }
}

enum WindowActivationMode { case raiseWindow, activateApplication }

struct WindowInfo: Identifiable, Hashable {
    let id: WindowIdentity
    let windowServerID: CGWindowID?
    let ownerPID: pid_t
    let processLaunchDate: Date?
    let activationPID: pid_t
    let activationProcessLaunchDate: Date?
    let bundleIdentifier: String, applicationName: String, title: String
    let bounds: CGRect
    let isOnScreen: Bool, isMinimized: Bool, isFullScreen: Bool
    let activationMode: WindowActivationMode
    let spaceIdentifier: UInt64?, spaceNumber: Int?
    let spaceLocations: [SpaceLocation]
    let isOnAllDesktops: Bool
    let screenName: String
    let icon: NSImage?
    let accessibilityIdentifier: String
    let accessibilityOrdinal: Int?
    let isAccessibilityFocused: Bool
    let titleOccurrence: Int?, titleOccurrenceCount: Int

    init(id: CGWindowID, ownerPID: pid_t, bundleIdentifier: String, applicationName: String,
         title: String, bounds: CGRect, isOnScreen: Bool, isMinimized: Bool,
         isFullScreen: Bool = false, activationMode: WindowActivationMode = .raiseWindow,
         spaceIdentifier: UInt64? = nil, spaceNumber: Int? = nil, screenName: String = "",
         icon: NSImage?, accessibilityIdentifier: String = "", accessibilityOrdinal: Int? = nil,
         isAccessibilityFocused: Bool = false, titleOccurrence: Int? = nil,
         titleOccurrenceCount: Int = 1, processLaunchDate: Date? = nil,
         spaceLocations: [SpaceLocation] = [], isOnAllDesktops: Bool = false,
         activationPID: pid_t? = nil, activationProcessLaunchDate: Date? = nil) {
        self.init(identity: .windowServer(ownerPID: ownerPID, launchDate: processLaunchDate, id: id), windowServerID: id,
                  ownerPID: ownerPID, bundleIdentifier: bundleIdentifier, applicationName: applicationName,
                  title: title, bounds: bounds, isOnScreen: isOnScreen, isMinimized: isMinimized,
                  isFullScreen: isFullScreen, activationMode: activationMode, spaceIdentifier: spaceIdentifier,
                  spaceNumber: spaceNumber, screenName: screenName, icon: icon,
                  accessibilityIdentifier: accessibilityIdentifier, accessibilityOrdinal: accessibilityOrdinal,
                  isAccessibilityFocused: isAccessibilityFocused, titleOccurrence: titleOccurrence,
                  titleOccurrenceCount: titleOccurrenceCount, processLaunchDate: processLaunchDate,
                  spaceLocations: spaceLocations, isOnAllDesktops: isOnAllDesktops,
                  activationPID: activationPID, activationProcessLaunchDate: activationProcessLaunchDate)
    }

    init(identity: WindowIdentity, windowServerID: CGWindowID?, ownerPID: pid_t,
         bundleIdentifier: String, applicationName: String, title: String, bounds: CGRect,
         isOnScreen: Bool, isMinimized: Bool, isFullScreen: Bool = false,
         activationMode: WindowActivationMode = .raiseWindow, spaceIdentifier: UInt64? = nil,
         spaceNumber: Int? = nil, screenName: String = "", icon: NSImage?,
         accessibilityIdentifier: String = "", accessibilityOrdinal: Int? = nil,
         isAccessibilityFocused: Bool = false, titleOccurrence: Int? = nil,
         titleOccurrenceCount: Int = 1, processLaunchDate: Date? = nil,
         spaceLocations: [SpaceLocation] = [], isOnAllDesktops: Bool = false,
         activationPID: pid_t? = nil, activationProcessLaunchDate: Date? = nil) {
        id = identity; self.windowServerID = windowServerID; self.ownerPID = ownerPID
        self.processLaunchDate = processLaunchDate; self.activationPID = activationPID ?? ownerPID
        self.activationProcessLaunchDate = activationProcessLaunchDate ?? processLaunchDate
        self.bundleIdentifier = bundleIdentifier; self.applicationName = applicationName; self.title = title
        self.bounds = bounds; self.isOnScreen = isOnScreen; self.isMinimized = isMinimized; self.isFullScreen = isFullScreen
        self.activationMode = activationMode; self.spaceIdentifier = spaceIdentifier; self.spaceNumber = spaceNumber
        self.spaceLocations = spaceLocations; self.isOnAllDesktops = isOnAllDesktops; self.screenName = screenName
        self.icon = icon; self.accessibilityIdentifier = accessibilityIdentifier; self.accessibilityOrdinal = accessibilityOrdinal
        self.isAccessibilityFocused = isAccessibilityFocused; self.titleOccurrence = titleOccurrence
        self.titleOccurrenceCount = titleOccurrenceCount
    }

    var applicationIdentifier: String { bundleIdentifier.isEmpty ? "\(activationPID)-\(applicationName)" : bundleIdentifier }
    var spaceState: WindowSpaceState { if isFullScreen { return .fullScreen }; if isMinimized { return .minimized }; return isOnScreen ? .current : .another }
    var spaceDescription: String { screenName.isEmpty ? spaceLabel : "\(spaceLabel) · \(screenName)" }
    var spaceLabel: String {
        if isOnAllDesktops { return isMinimized ? "Todos os Desktops · Minimizada" : "Todos os Desktops" }
        if spaceLocations.count > 1 { let numbers = spaceLocations.compactMap(\.number).map(String.init).joined(separator: ", "); return numbers.isEmpty ? "Múltiplos Spaces" : "Spaces \(numbers)" + (isMinimized ? " · Minimizada" : "") }
        guard let spaceNumber else { return spaceState.title }
        return switch spaceState { case .current, .another: "Space \(spaceNumber)"; case .minimized: "Space \(spaceNumber) · Minimizada"; case .fullScreen: "Space \(spaceNumber) · Tela Cheia" }
    }
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty || ["window", "janela"].contains(trimmed.lowercased()) ? applicationName : trimmed
        guard titleOccurrenceCount > 1, let titleOccurrence else { return base }; return "\(base) · Janela \(titleOccurrence)"
    }

    private func rebuilt(title: String? = nil, minimized: Bool? = nil, fullScreen: Bool? = nil,
                         mode: WindowActivationMode? = nil, axIdentifier: String? = nil,
                         axOrdinal: Int? = nil, focused: Bool? = nil, occurrence: Int? = nil,
                         occurrenceCount: Int? = nil, resolved: ResolvedWindowSpace? = nil,
                         replaceSpace: Bool = false) -> WindowInfo {
        WindowInfo(identity: id, windowServerID: windowServerID, ownerPID: ownerPID,
            bundleIdentifier: bundleIdentifier, applicationName: applicationName, title: title ?? self.title,
            bounds: bounds, isOnScreen: isOnScreen, isMinimized: minimized ?? isMinimized,
            isFullScreen: fullScreen ?? (isFullScreen || (resolved?.isFullScreen ?? false)), activationMode: mode ?? activationMode,
            spaceIdentifier: replaceSpace ? resolved?.identifier : spaceIdentifier,
            spaceNumber: replaceSpace ? resolved?.number : spaceNumber, screenName: screenName, icon: icon,
            accessibilityIdentifier: axIdentifier ?? accessibilityIdentifier,
            accessibilityOrdinal: axOrdinal ?? accessibilityOrdinal, isAccessibilityFocused: focused ?? isAccessibilityFocused,
            titleOccurrence: occurrence ?? titleOccurrence, titleOccurrenceCount: occurrenceCount ?? titleOccurrenceCount,
            processLaunchDate: processLaunchDate, spaceLocations: replaceSpace ? (resolved?.locations ?? []) : spaceLocations,
            isOnAllDesktops: replaceSpace ? (resolved?.isOnAllDesktops ?? false) : isOnAllDesktops,
            activationPID: activationPID, activationProcessLaunchDate: activationProcessLaunchDate)
    }
    func withAccessibilityIdentity(identifier: String, ordinal: Int, accessibilityTitle: String,
        isMinimized: Bool, isFullScreen: Bool, isFocused: Bool, activationMode: WindowActivationMode? = nil) -> WindowInfo {
        rebuilt(title: accessibilityTitle.isEmpty ? title : accessibilityTitle, minimized: isMinimized,
                fullScreen: isFullScreen, mode: activationMode, axIdentifier: identifier,
                axOrdinal: ordinal, focused: isFocused)
    }
    func withTitleOccurrence(_ occurrence: Int, count: Int) -> WindowInfo { rebuilt(occurrence: occurrence, occurrenceCount: count) }
    func withResolvedSpace(_ resolvedSpace: ResolvedWindowSpace?) -> WindowInfo { rebuilt(resolved: resolvedSpace, replaceSpace: true) }
    func withActivationMode(_ mode: WindowActivationMode) -> WindowInfo { rebuilt(mode: mode) }
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
