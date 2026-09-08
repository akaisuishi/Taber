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
    let bundleIdentifier: String, applicationName: String
    private(set) var title: String
    let bounds: CGRect
    let isOnScreen: Bool
    private(set) var isMinimized: Bool
    private(set) var isFullScreen: Bool
    private(set) var activationMode: WindowActivationMode
    private(set) var spaceIdentifier: UInt64?
    private(set) var spaceNumber: Int?
    private(set) var spaceLocations: [SpaceLocation]
    private(set) var isOnAllDesktops: Bool
    let screenName: String
    let icon: NSImage?
    private(set) var accessibilityIdentifier: String
    private(set) var accessibilityOrdinal: Int?
    private(set) var isAccessibilityFocused: Bool
    private(set) var titleOccurrence: Int?
    private(set) var titleOccurrenceCount: Int

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

    func withAccessibilityIdentity(identifier: String, ordinal: Int, accessibilityTitle: String,
        isMinimized: Bool, isFullScreen: Bool, isFocused: Bool, activationMode: WindowActivationMode? = nil) -> WindowInfo {
        var copy = self
        if !accessibilityTitle.isEmpty { copy.title = accessibilityTitle }
        copy.isMinimized = isMinimized
        copy.isFullScreen = isFullScreen
        if let activationMode { copy.activationMode = activationMode }
        copy.accessibilityIdentifier = identifier
        copy.accessibilityOrdinal = ordinal
        copy.isAccessibilityFocused = isFocused
        return copy
    }
    func withTitleOccurrence(_ occurrence: Int, count: Int) -> WindowInfo {
        var copy = self
        copy.titleOccurrence = occurrence
        copy.titleOccurrenceCount = count
        return copy
    }
    func withResolvedSpace(_ resolvedSpace: ResolvedWindowSpace?) -> WindowInfo {
        var copy = self
        copy.spaceIdentifier = resolvedSpace?.identifier
        copy.spaceNumber = resolvedSpace?.number
        copy.spaceLocations = resolvedSpace?.locations ?? []
        copy.isOnAllDesktops = resolvedSpace?.isOnAllDesktops ?? false
        copy.isFullScreen = isFullScreen || (resolvedSpace?.isFullScreen ?? false)
        return copy
    }
    func withActivationMode(_ mode: WindowActivationMode) -> WindowInfo {
        var copy = self
        copy.activationMode = mode
        return copy
    }
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
