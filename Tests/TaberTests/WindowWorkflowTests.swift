import AppKit
import XCTest

@MainActor
final class FixtureSource: WindowSnapshotSource {
    var frontmostPID: pid_t? = 42
    var raw: [WindowInfo] = []
    var ax: [AccessibilityWindowSnapshot] = []
    var locations: [CGWindowID: ResolvedWindowSpace] = [:]
    func candidates(includeUtilityWindows: Bool) -> [WindowInfo] { raw }
    func accessibilityWindows(for pid: pid_t, includeUtilityWindows: Bool) -> [AccessibilityWindowSnapshot] { ax }
    func spaces(for ids: [CGWindowID]) -> [CGWindowID: ResolvedWindowSpace] { locations }
}

@MainActor
final class ManualActivationClock: ActivationClock {
    var pending: [@MainActor () -> Void] = []
    func schedule(after delay: Duration, operation: @escaping @MainActor () -> Void) { pending.append(operation) }
    func advance() { let work = pending; pending = []; work.forEach { $0() } }
}

@MainActor
final class FixtureDriver: WindowActivationDriving {
    var exists = true
    var isMinimized = true
    var operations: [String] = []
    func resolve(_ window: WindowInfo) -> Bool { operations.append("resolve"); return exists }
    func restore() { operations.append("restore") }
    func focus() { operations.append("focus") }
    func activateApplication() { operations.append("activate") }
}

@MainActor
final class ApplicationFixtureDriver: WindowActivationDriving,
    ApplicationOnlyActivationDriving, ProcessValidatingActivationDriving {
    var processIsValid = true
    var applicationTargetIsValid = true
    var isMinimized = false
    var operations: [String] = []

    func validateProcess(_ window: WindowInfo) -> Bool {
        operations.append("validate-process")
        return processIsValid
    }
    func validateApplicationTarget(_ window: WindowInfo) -> Bool {
        operations.append("validate-application")
        return applicationTargetIsValid
    }
    func resolve(_ window: WindowInfo) -> Bool {
        operations.append("resolve")
        return false
    }
    func restore() { operations.append("restore") }
    func focus() { operations.append("focus") }
    func activateApplication() { operations.append("activate") }
}

@MainActor
final class WindowWorkflowTests: XCTestCase {
    let rect = CGRect(x: 20, y: 40, width: 800, height: 600)

    func window(_ id: UInt32 = 1, title: String = "Documento", minimized: Bool = false,
                full: Bool = false, mode: WindowActivationMode = .raiseWindow,
                bundle: String = "com.apple.finder", pid: pid_t = 42) -> WindowInfo {
        WindowInfo(id: id, ownerPID: pid, bundleIdentifier: bundle, applicationName: "Fixture",
                   title: title, bounds: rect, isOnScreen: !minimized, isMinimized: minimized,
                   isFullScreen: full, activationMode: mode, icon: nil)
    }
    func ax(_ id: UInt32?, focused: Bool = false, main: Bool = false, minimized: Bool = false,
            title: String = "Documento", subrole: String = "AXStandardWindow", document: String = "",
            identifier: String? = nil, ordinal: Int? = nil, role: String = "") -> AccessibilityWindowSnapshot {
        AccessibilityWindowSnapshot(windowID: id, identifier: identifier ?? id.map(String.init) ?? "", title: title,
            document: document, subrole: subrole, bounds: rect, isMinimized: minimized,
            isMain: main, isFocused: focused, ordinal: ordinal ?? Int(id ?? 0), role: role)
    }
    func manager(_ raw: [WindowInfo], _ snapshots: [AccessibilityWindowSnapshot]) -> (WindowManager, FixtureSource) {
        let source = FixtureSource(); source.raw = raw; source.ax = snapshots
        let manager = WindowManager(source: source); manager.refresh()
        return (manager, source)
    }
    func candidate(_ id: UInt32?, title: String = "Documento", ordinal: Int = 0) -> ActivationCandidate {
        ActivationCandidate(windowID: id, identifier: "", title: title, bounds: rect, isMinimized: false, ordinal: ordinal)
    }
    func accessibilityWindow(identifier: String = "settings", title: String = "Configurações",
                             pid: pid_t = 42, launchDate: Date? = nil, ordinal: Int = 0,
                             minimized: Bool = false) -> WindowInfo {
        let fallback = AccessibilityWindowFallback(document: "", title: title, bounds: rect, ordinal: ordinal)
        return WindowInfo(identity: .accessibility(ownerPID: pid, launchDate: launchDate,
            identifier: identifier, fallback: fallback), windowServerID: nil, ownerPID: pid,
            bundleIdentifier: "com.taber.fixture", applicationName: "Taber", title: title,
            bounds: rect, isOnScreen: !minimized, isMinimized: minimized, icon: nil,
            accessibilityIdentifier: identifier, accessibilityOrdinal: ordinal,
            processLaunchDate: launchDate)
    }
    func monitor(_ source: FixtureSource, style: SwitcherStyle = .list) -> (GlobalShortcutMonitor, SwitcherPanelController, SettingsStore) {
        let defaults = UserDefaults(suiteName: "com.taber.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults); settings.switcherStyle = style
        let panel = SwitcherPanelController()
        panel.model.isDemo = true
        let monitor = GlobalShortcutMonitor(windowManager: WindowManager(source: source), settings: settings,
            panelController: panel, initialState: .active, now: { 1 }, activate: { _ in })
        return (monitor, panel, settings)
    }

    func test01NoEligibleWindowsDoesNotStartCycle() async {
        let (m, p, _) = monitor(FixtureSource())
        m.beginOrAdvanceCycle(reverse: false)
        XCTAssertTrue(p.model.windows.isEmpty)
        m.finishCycle(); m.cancelCycle()
    }
    func test02OneWindowUsesOneCellAcrossAllSizesAndStyles() async {
        for style in SwitcherStyle.allCases { for size in SwitcherSize.allCases {
            let one = SwitcherPanelController.requestedSize(for: style, windows: [window()], metrics: .init(size: size), isSearching: false)
            let two = SwitcherPanelController.requestedSize(for: style, windows: [window(), window(2)], metrics: .init(size: size), isSearching: false)
            XCTAssertTrue(one.width < two.width || one.height < two.height, "\(style) \(size)")
        }}
    }
    func test03AXFocusOverridesWindowServerOrder() async {
        let (m, _) = manager([window(), window(2)], [ax(1), ax(2, focused: true)])
        XCTAssertEqual(m.frontmostWindow()?.windowServerID, 2)
    }
    func test04FocusedWindowWinsOverMainWindow() async {
        let (m, _) = manager([window(), window(2)], [ax(1, main: true), ax(2, focused: true)])
        XCTAssertEqual(m.frontmostWindow()?.windowServerID, 2)
    }
    func test05ChromeNormalAndIncognitoSelectExactIdentity() async {
        for id: UInt32 in [1, 2] {
            XCTAssertEqual(WindowMatchingPolicy.activationCandidateIndex(for: window(id, bundle: "com.google.Chrome"),
                in: [candidate(1), candidate(2)]), Int(id - 1))
        }
    }
    func test06SafariPrivateAndNormalRemainDistinct() async {
        let (m, _) = manager([window(bundle: "com.apple.Safari"), window(2, bundle: "com.apple.Safari")], [ax(1), ax(2)])
        XCTAssertEqual(m.windows.compactMap(\.windowServerID), [1, 2])
    }
    func test07FinderEqualTitlesGetDistinctLabels() async {
        let (m, _) = manager([window(), window(2)], [ax(1), ax(2)])
        XCTAssertNotEqual(m.windows[0].displayTitle, m.windows[1].displayTitle)
    }
    func test08OverlappingWindowsSurviveAXUnavailable() async {
        let (m, _) = manager([window(title: "Documento A"), window(2, title: "Documento B")], [])
        XCTAssertEqual(m.windows.count, 2)
    }
    func test09ImmediateMinimizeUsesAXState() async {
        let (m, _) = manager([window()], [ax(1, minimized: true)])
        XCTAssertTrue(m.windows[0].isMinimized)
        XCTAssertNil(m.frontmostWindow())
    }
    func test10AllMinimizedWindowsRemainAvailable() async {
        let (m, _) = manager([window(minimized: true), window(2, minimized: true)], [ax(1, minimized: true), ax(2, minimized: true)])
        XCTAssertEqual(m.windows.count, 2)
        XCTAssertTrue(m.windows.allSatisfy(\.isMinimized))
    }
    func test11RestoreDoesNotTouchOtherMinimizedWindows() async {
        let a = FixtureDriver(), b = FixtureDriver()
        let c = WindowActivationCoordinator(clock: ManualActivationClock()) { $0.windowServerID == 1 ? a : b }
        c.activate(window(2, minimized: true))
        XCTAssertTrue(a.operations.isEmpty)
        XCTAssertTrue(b.operations.contains("restore"))
    }
    func test12OldRestoreCannotStealNewSelection() async {
        let clock = ManualActivationClock(), a = FixtureDriver(), b = FixtureDriver()
        let c = WindowActivationCoordinator(clock: clock) { $0.windowServerID == 1 ? a : b }
        c.activate(window(minimized: true)); c.activate(window(2))
        let before = a.operations.count; clock.advance()
        XCTAssertEqual(a.operations.count, before)
    }
    func test13HiddenApplicationIsActivatedAfterTargetResolution() async {
        let d = FixtureDriver()
        WindowActivationCoordinator(clock: ManualActivationClock()) { _ in d }.activate(window())
        XCTAssertEqual(d.operations.first, "resolve")
        XCTAssertTrue(d.operations.contains("activate"))
    }
    func test14ClosedWindowDoesNotActivateDifferentWindow() async {
        let d = FixtureDriver(); d.exists = false
        WindowActivationCoordinator(clock: ManualActivationClock()) { _ in d }.activate(window())
        XCTAssertFalse(d.operations.contains("activate"))
    }
    func test15StaleWindowIDDoesNotMatchReplacementByGeometry() async {
        XCTAssertNil(WindowMatchingPolicy.activationCandidateIndex(for: window(), in: [candidate(99)]))
    }
    func test16OtherSpaceIsDisplayed() async {
        let (m, s) = manager([window()], [ax(1)])
        s.locations[1] = ResolvedWindowSpace(identifier: 20, number: 2, isFullScreen: false)
        m.refresh(); XCTAssertEqual(m.windows[0].spaceLabel, "Space 2")
    }
    func test17ReorderedSpacesRecomputeDesktopNumbers() async {
        let a: [String: Any] = ["id64": 10, "type": 0], b: [String: Any] = ["id64": 20, "type": 0]
        XCTAssertEqual(SpaceResolver.managedSpaceMap(from: [["Spaces": [a, b]]])[10]?.number, 1)
        XCTAssertEqual(SpaceResolver.managedSpaceMap(from: [["Spaces": [b, a]]])[10]?.number, 2)
    }
    func test18UnknownSpaceDoesNotInventDesktopNumber() async {
        let (m, _) = manager([window()], [ax(1)])
        XCTAssertNil(m.windows[0].spaceNumber)
        XCTAssertFalse(m.windows[0].spaceLabel.contains("Space 1"))
        let map = SpaceResolver.managedSpaceMap(from: [["Spaces": [["id64": 1, "type": 0], ["id64": 2, "type": 0], ["id64": 3, "type": 0]]]])
        let multiple = SpaceResolver.resolveMembership([1, 2], managed: map)
        XCTAssertNil(multiple?.number)
        XCTAssertEqual(window().withResolvedSpace(multiple).spaceLabel, "Spaces 1, 2")
        let all = SpaceResolver.resolveMembership([1, 2, 3], managed: map)
        XCTAssertEqual(window().withResolvedSpace(all).spaceLabel, "Todos os Desktops")
        XCTAssertNil(SpaceResolver.resolveMembership([99], managed: map))
    }
    func test19SeparateDisplaySpacesHaveDistinctNumbers() async {
        let map = SpaceResolver.managedSpaceMap(from: [
            ["Display Identifier": "A", "Spaces": [["id64": 10, "type": 0]]],
            ["Display Identifier": "B", "Spaces": [["id64": 20, "type": 0]]]])
        XCTAssertNotEqual(map[10]?.number, map[20]?.number)
        XCTAssertEqual(map[20]?.displayIdentifier, "B")
    }
    func test20SmallScreenMetricsStayFinite() async {
        for style in SwitcherStyle.allCases {
            let size = SwitcherPanelController.requestedSize(for: style, windows: [window()], metrics: .init(size: .compact), isSearching: true)
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertGreaterThan(size.width, 0)
            for frame in [CGRect(x: 0, y: 0, width: 640, height: 480), CGRect(x: -1280, y: -720, width: 1280, height: 720)] {
                XCTAssertTrue(frame.contains(SwitcherPanelController.fittedFrame(requested: size, visibleFrame: frame)))
            }
        }
    }
    func test21NativeFullscreenKeepsExactWindowActivation() async {
        let (m, _) = manager([window(full: true)], [ax(1)])
        XCTAssertEqual(m.windows[0].activationMode, .raiseWindow)
        XCTAssertTrue(m.windows[0].isFullScreen)
    }
    func test22SafariVideoPresentationUsesApplicationActivation() async {
        let d = FixtureDriver()
        WindowActivationCoordinator(clock: ManualActivationClock()) { _ in d }
            .activate(window(full: true, mode: .activateApplication, bundle: "com.apple.Safari"))
        XCTAssertTrue(d.operations.contains("activate"))
        XCTAssertFalse(d.operations.contains("restore"))
    }
    func test23ChromePlayerUsesMatchingDocumentHost() async {
        XCTAssertEqual(WindowMatchingPolicy.preferredContentHostIndex(presentationOrdinal: 0,
            presentationDocument: "file:///fixture/b", candidates: [(0, 0, "file:///fixture/a"), (1, 3, "file:///fixture/b")]), 1)
    }
    func test24PictureInPictureUtilityPolicy() async {
        let context = WindowEligibilityContext(bundleIdentifier: "com.fixture.pip", activationPolicy: .accessory,
            title: "Picture in Picture", bounds: rect, layer: 0, alpha: 1, isOnScreen: true,
            isHelperProcess: false, evidence: .accessibility,
            accessibilitySubrole: kAXFloatingWindowSubrole as String)
        XCTAssertFalse(WindowEligibilityPolicy.allows(context, includeUtilityWindows: false))
        XCTAssertTrue(WindowEligibilityPolicy.allows(context, includeUtilityWindows: true))
    }
    func test25ModalDialogIdentityIsNotMergedByTitle() async {
        let (m, _) = manager([window(), window(2)], [ax(1), ax(2, focused: true, subrole: "AXDialog")])
        XCTAssertEqual(m.windows.count, 2)
        XCTAssertEqual(m.frontmostWindow()?.windowServerID, 2)
    }
    func test26BackgroundHelpersAreExcluded() async {
        for (bundle, policy, helper) in [("com.apple.Spotlight", NSApplication.ActivationPolicy.regular, false),
            ("com.google.drivefs", .accessory, false)] {
            let c = WindowEligibilityContext(bundleIdentifier: bundle, activationPolicy: policy, title: "",
                bounds: rect, layer: 0, alpha: 1, isOnScreen: false, isHelperProcess: helper)
            XCTAssertFalse(WindowEligibilityPolicy.allows(c, includeUtilityWindows: true))
        }
    }
    func test27AXUnavailablePreservesCredibleFallback() async {
        let (m, _) = manager([window()], [])
        XCTAssertEqual(m.windows.count, 1)
    }
    func test28MissingCaptureDoesNotBlockModelSelection() async {
        let model = SwitcherViewModel()
        model.present(windows: [window(), window(2)], selectedIndex: 0, style: .preview, theme: .original, size: .medium)
        model.select(index: 1)
        XCTAssertEqual(model.windows[model.selectedIndex].windowServerID, 2)
    }
    func test29SearchAccentsEmptyResultsAndDetachedCommand() async {
        let s = FixtureSource(); s.raw = [window(title: "Relatório"), window(2, title: "Notas")]; s.ax = [ax(1, title: "Relatório"), ax(2, title: "Notas")]
        let (m, p, _) = monitor(s)
        m.beginOrAdvanceCycle(reverse: false); m.enterSearch()
        m.handleSearchInput(keyCode: 0, text: "relatorio")
        XCTAssertEqual(p.model.windows.compactMap(\.windowServerID), [1])
        m.detachSearchFromCommand(); XCTAssertTrue(p.model.isSearchDetached)
        m.handleSearchInput(keyCode: 0, text: "inexistente")
        XCTAssertTrue(p.model.windows.isEmpty)
        m.handleEscape()
    }
    func test30RepeatedTabReverseArrowsAndEscape() async {
        for style in SwitcherStyle.allCases {
            let s = FixtureSource(); s.raw = [window(), window(2), window(3)]; s.ax = [ax(1, focused: true), ax(2), ax(3)]
            let (m, p, _) = monitor(s, style: style)
            m.beginOrAdvanceCycle(reverse: false); XCTAssertEqual(p.model.selectedIndex, 1)
            m.beginOrAdvanceCycle(reverse: false); XCTAssertEqual(p.model.selectedIndex, 2)
            m.beginOrAdvanceCycle(reverse: true); XCTAssertEqual(p.model.selectedIndex, 1)
            m.navigate(using: style.navigationAxis == .horizontal ? 123 : 126)
            XCTAssertEqual(p.model.selectedIndex, 0)
            m.handleEscape()
        }
    }
    func test31VMAndRemoteSessionRemainHostWindows() async {
        for bundle in ["com.utmapp.UTM", "company.thebrowser.Browser"] {
            let (m, _) = manager([window(title: "Sessão local fictícia", bundle: bundle)], [ax(1)])
            XCTAssertEqual(m.windows.count, 1)
            XCTAssertEqual(m.windows[0].bundleIdentifier, bundle)
        }
    }
    func test32ManyWindowsRapidPresentationsKeepLatestSelection() async {
        let many = (1...200).map { window(UInt32($0)) }
        let model = SwitcherViewModel()
        for i in 0..<100 {
            model.present(windows: many, selectedIndex: i, style: .flow, theme: .original, size: .compact)
        }
        XCTAssertEqual(model.thumbnailGeneration, 100)
        XCTAssertEqual(model.selectedIndex, 99)
        XCTAssertEqual(model.windows.count, 200)
        var budget = ThumbnailRequestBudget()
        let old = budget.acquire()!
        budget.begin()
        XCTAssertFalse(budget.accepts(old))
        for _ in 0..<100 { _ = budget.acquire() }
        XCTAssertEqual(budget.active, budget.limit)
        for _ in 0..<100 { budget.release() }
        XCTAssertEqual(budget.active, 0)
    }

    func test34AXOnlyMinimizedWindowSurvivesWindowServerTransition() async {
        let (m, _) = manager([window()], [ax(1), ax(2, minimized: true)])
        XCTAssertEqual(m.windows.compactMap(\.windowServerID), [1, 2])
        XCTAssertTrue(m.windows[1].isMinimized)
    }

    func test35AmbiguousLegacyIdentityIsRejected() async {
        XCTAssertNil(WindowMatchingPolicy.activationCandidateIndex(for: window(), in: [candidate(nil), candidate(nil, ordinal: 8)]))
        XCTAssertNil(WindowMatchingPolicy.preferredContentHostIndex(presentationOrdinal: 0, presentationDocument: "",
            candidates: [(0, 1, ""), (1, 2, "")], requireUniqueHost: true))
    }

    func test36NoCurrentWindowDoesNotSkipFirstMinimizedTarget() async {
        let s = FixtureSource()
        s.raw = [window(minimized: true), window(2, minimized: true)]
        s.ax = [ax(1, minimized: true), ax(2, minimized: true)]
        let (m, p, _) = monitor(s)
        m.beginOrAdvanceCycle(reverse: false)
        XCTAssertEqual(p.model.selectedIndex, 0)
        m.cancelCycle()
    }

    func test37ClosedPresentationHostIsNotActivated() async {
        let d = FixtureDriver(); d.exists = false
        WindowActivationCoordinator(clock: ManualActivationClock()) { _ in d }
            .activate(window(full: true, mode: .activateApplication))
        XCTAssertEqual(d.operations, ["resolve"])
    }

    func test38NewCycleCancelsOutstandingRestoration() async {
        let d = FixtureDriver(), clock = ManualActivationClock()
        let c = WindowActivationCoordinator(clock: clock) { _ in d }
        c.activate(window(minimized: true))
        c.cancelPending(); let before = d.operations
        clock.advance()
        XCTAssertEqual(d.operations, before)
    }

    func test39TransparencyDefaultsToDisabled() async {
        let suite = "com.taber.tests.transparency-default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(SettingsStore(defaults: defaults).transparencyEnabled)
    }

    func test40TransparencyPreferencePersistsWithoutChangingItsDefault() async {
        let suite = "com.taber.tests.transparency-persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstStore = SettingsStore(defaults: defaults)
        firstStore.transparencyEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).transparencyEnabled)

        firstStore.transparencyEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).transparencyEnabled)
    }

    func test41ReduceTransparencyAlwaysOverridesSavedPreference() async {
        XCTAssertTrue(TaberTransparencyPolicy.isEffective(userEnabled: true, reduceTransparency: false))
        XCTAssertFalse(TaberTransparencyPolicy.isEffective(userEnabled: true, reduceTransparency: true))
        XCTAssertFalse(TaberTransparencyPolicy.isEffective(userEnabled: false, reduceTransparency: false))
        XCTAssertFalse(TaberTransparencyPolicy.isEffective(userEnabled: false, reduceTransparency: true))
    }

    func test60AXOnlyWindowsHaveStableTypedIdentitiesWithoutInventedCGIDs() async {
        let snapshots = [
            ax(1, title: "Janela CG"),
            ax(nil, minimized: true, title: "Projeto", identifier: "AX-project", ordinal: 4),
            ax(nil, minimized: true, title: "Projeto", identifier: "", ordinal: 5)
        ]
        let (manager, _) = manager([window()], snapshots)
        let axOnly = manager.windows.filter { $0.windowServerID == nil }

        XCTAssertEqual(axOnly.count, 2)
        XCTAssertEqual(Set(axOnly.map(\.id)).count, 2)
        XCTAssertTrue(axOnly.allSatisfy(\.isMinimized))
        guard case let .accessibility(pid, _, identifier, fallback) = axOnly[0].id else {
            return XCTFail("A janela AX-only deve manter identidade AX tipada")
        }
        XCTAssertEqual(pid, 42)
        XCTAssertEqual(identifier, "AX-project")
        XCTAssertEqual(fallback.ordinal, 4)
    }

    func test61DuplicateAXIdentifiersAndFallbackTiesNeverPickArbitrarily() async {
        let target = accessibilityWindow(identifier: "duplicated", title: "Mesmo título")
        let duplicateIdentifiers = [
            ActivationCandidate(windowID: nil, identifier: "duplicated", title: "Mesmo título",
                bounds: rect, isMinimized: false, ordinal: 0),
            ActivationCandidate(windowID: nil, identifier: "duplicated", title: "Mesmo título",
                bounds: rect, isMinimized: false, ordinal: 1)
        ]
        XCTAssertNil(WindowMatchingPolicy.activationCandidateIndex(for: target, in: duplicateIdentifiers))

        let noIdentifier = accessibilityWindow(identifier: "", title: "Mesmo título")
        XCTAssertNil(WindowMatchingPolicy.activationCandidateIndex(for: noIdentifier, in: duplicateIdentifiers))
    }

    func test62NestedAccessoryAndProhibitedRenderersNeedCredibleUserSurfaces() async {
        for policy in [NSApplication.ActivationPolicy.accessory, .prohibited] {
            let legitimate = WindowEligibilityContext(bundleIdentifier: "com.riotgames.LeagueOfLegends.Game",
                activationPolicy: policy, title: "League of Legends", bounds: rect,
                layer: 0, alpha: 1, isOnScreen: true, isHelperProcess: true)
            let decision = WindowEligibilityPolicy.evaluate(legitimate, includeUtilityWindows: false)
            XCTAssertTrue(decision.isEligible)
            XCTAssertEqual(decision.reason, .nestedRenderer)

            let technical = WindowEligibilityContext(bundleIdentifier: "com.riotgames.helper",
                activationPolicy: policy, title: "", bounds: CGRect(x: 0, y: 0, width: 32, height: 32),
                layer: 0, alpha: 1, isOnScreen: false, isHelperProcess: true)
            XCTAssertFalse(WindowEligibilityPolicy.allows(technical, includeUtilityWindows: true))
        }
    }

    func test63LeagueLikeCGOnlyRendererActivatesValidatedHostApplication() async {
        let launchDate = Date(timeIntervalSince1970: 1_700_000_000)
        let game = WindowInfo(id: 501, ownerPID: 700,
            bundleIdentifier: "com.riotgames.LeagueOfLegends.Game", applicationName: "League of Legends",
            title: "", bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            isOnScreen: true, isMinimized: false, isFullScreen: true,
            activationMode: .activateApplication, icon: nil, processLaunchDate: launchDate,
            activationPID: 701, activationProcessLaunchDate: launchDate)
        let driver = ApplicationFixtureDriver()
        let result = WindowActivationCoordinator(clock: ManualActivationClock()) { _ in driver }.activate(game)

        XCTAssertEqual(result.strategy, .application)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(driver.operations,
            ["validate-process", "validate-application", "activate"])
        XCTAssertFalse(driver.operations.contains("resolve"))
        XCTAssertFalse(driver.operations.contains("focus"))
    }

    func test64TerminatedOrRestartedProcessIsRejectedBeforeActivation() async {
        let expected = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(WindowMatchingPolicy.representsSameProcess(expectedPID: 90,
            expectedBundleIdentifier: "com.fixture", expectedLaunchDate: expected,
            actualPID: 90, actualBundleIdentifier: "com.fixture",
            actualLaunchDate: Date(timeIntervalSince1970: 101)))
        XCTAssertFalse(WindowMatchingPolicy.representsSameProcess(expectedPID: 90,
            expectedBundleIdentifier: "com.fixture", expectedLaunchDate: expected,
            actualPID: 91, actualBundleIdentifier: "com.fixture", actualLaunchDate: expected))

        let driver = ApplicationFixtureDriver()
        driver.processIsValid = false
        let result = WindowActivationCoordinator(clock: ManualActivationClock()) { _ in driver }
            .activate(window(mode: .activateApplication))
        XCTAssertEqual(result.outcome, .rejected(.staleProcess))
        XCTAssertEqual(driver.operations, ["validate-process"])
    }

    func test65RestoreSequenceAndRetryStayBoundToResolvedTarget() async {
        let driver = FixtureDriver()
        let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock) { _ in driver }
        let result = coordinator.activate(window(minimized: true))

        XCTAssertEqual(result.steps, [.targetResolved, .restored, .applicationActivated,
            .focusedAndRaised, .retryScheduled])
        XCTAssertEqual(driver.operations, ["resolve", "restore", "activate", "focus"])
        clock.advance()
        XCTAssertEqual(driver.operations,
            ["resolve", "restore", "activate", "focus", "resolve", "restore", "activate", "focus"])
    }

    func test66SheetsDialogsAndUtilitiesFollowExplicitEvidencePolicy() async {
        let dialog = WindowEligibilityContext(bundleIdentifier: "com.fixture", activationPolicy: .regular,
            title: "Salvar", bounds: rect, layer: 3, alpha: 0, isOnScreen: false,
            isHelperProcess: false, evidence: .accessibility,
            accessibilitySubrole: kAXDialogSubrole as String)
        XCTAssertEqual(WindowEligibilityPolicy.evaluate(dialog, includeUtilityWindows: false).reason, .dialog)

        let sheet = WindowEligibilityContext(bundleIdentifier: "com.fixture", activationPolicy: .regular,
            title: "Documento", bounds: rect, layer: 9, alpha: 0, isOnScreen: false,
            isHelperProcess: false, evidence: .accessibility, accessibilitySubrole: "")
        let sheetDecision = WindowEligibilityPolicy.evaluate(sheet, includeUtilityWindows: false)
        XCTAssertTrue(sheetDecision.isEligible)
        XCTAssertEqual(sheetDecision.reason, .standardWindow)

        let utility = WindowEligibilityContext(bundleIdentifier: "com.fixture", activationPolicy: .accessory,
            title: "Paleta", bounds: rect, layer: 8, alpha: 1, isOnScreen: true,
            isHelperProcess: false, evidence: .accessibility,
            accessibilitySubrole: kAXFloatingWindowSubrole as String)
        XCTAssertEqual(WindowEligibilityPolicy.evaluate(utility, includeUtilityWindows: false).reason, .utilityDisabled)
        XCTAssertEqual(WindowEligibilityPolicy.evaluate(utility, includeUtilityWindows: true).reason, .utility)

        let (manager, _) = manager([window(), window(2)], [
            ax(1, title: "Documento", subrole: "", role: kAXSheetRole as String),
            ax(2, focused: true, title: "Salvar", subrole: kAXDialogSubrole as String)
        ])
        XCTAssertEqual(manager.windows.count, 2)
        XCTAssertEqual(manager.frontmostWindow()?.windowServerID, 2)
    }

    func test67ProtectedContentWithoutThumbnailRemainsSelectableAndActivatable() async {
        let protectedWindow = window(71, title: "Reprodução protegida", full: true,
            mode: .activateApplication, bundle: "com.fixture.streaming")
        XCTAssertNil(protectedWindow.icon)
        let model = SwitcherViewModel()
        model.present(windows: [window(), protectedWindow], selectedIndex: 1,
            style: .preview, theme: .dark, size: .medium)
        XCTAssertEqual(model.windows[model.selectedIndex].windowServerID, 71)

        let driver = FixtureDriver()
        let result = WindowActivationCoordinator(clock: ManualActivationClock()) { _ in driver }
            .activate(protectedWindow)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(driver.operations, ["resolve", "activate"])
    }

    func test68SettingsLocalWindowParticipatesAndUsesLocalActivation() async {
        let source = FixtureSource()
        var localActivationCount = 0
        var externalActivationCount = 0
        let settingsWindow = accessibilityWindow(identifier: "taber-settings", title: "Configurações",
            pid: ProcessInfo.processInfo.processIdentifier, minimized: true)
        let defaults = UserDefaults(suiteName: "com.taber.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let panel = SwitcherPanelController(); panel.model.isDemo = true
        let monitor = GlobalShortcutMonitor(windowManager: WindowManager(source: source), settings: settings,
            panelController: panel, initialState: .active, commandIsPressed: { true },
            additionalWindows: { [settingsWindow] }, activateLocally: { selected in
                guard selected.id == settingsWindow.id else { return false }
                localActivationCount += 1
                return true
            }, activate: { _ in externalActivationCount += 1 })

        monitor.beginOrAdvanceCycle(reverse: false)
        XCTAssertEqual(panel.model.windows.map(\.id), [settingsWindow.id])
        monitor.finishCycle()
        XCTAssertEqual(localActivationCount, 1)
        XCTAssertEqual(externalActivationCount, 0)
    }

    func test69TechnicalSystemSurfacesRemainExcluded() async {
        for bundle in ["com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver",
                       "com.apple.WindowManager", "com.apple.notificationcenterui",
                       "com.apple.TextInputSwitcher", "com.apple.AccessibilityVisualsAgent"] {
            let context = WindowEligibilityContext(bundleIdentifier: bundle, activationPolicy: .regular,
                title: "Painel", bounds: rect, layer: 0, alpha: 1, isOnScreen: true,
                isHelperProcess: false, evidence: .accessibility,
                accessibilitySubrole: kAXStandardWindowSubrole as String)
            let decision = WindowEligibilityPolicy.evaluate(context, includeUtilityWindows: true)
            XCTAssertFalse(decision.isEligible, bundle)
            XCTAssertEqual(decision.reason, .systemShell, bundle)
        }
    }

    func test70DisabledEventTapCancelsCycleWithoutCommittingSelection() async {
        let source = FixtureSource()
        source.raw = [window(), window(2)]
        source.ax = [ax(1, focused: true), ax(2)]
        var activations = 0
        let defaults = UserDefaults(suiteName: "com.taber.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let panel = SwitcherPanelController(); panel.model.isDemo = true
        let monitor = GlobalShortcutMonitor(windowManager: WindowManager(source: source), settings: settings,
            panelController: panel, initialState: .active, commandIsPressed: { true },
            activate: { _ in activations += 1 })

        monitor.beginOrAdvanceCycle(reverse: false)
        monitor.handleEventTapDisabled()
        monitor.finishCycle()
        XCTAssertEqual(activations, 0)
    }

    func test71CommandReleaseWatchdogFinishesLostCommandUp() async throws {
        let source = FixtureSource()
        source.raw = [window(), window(2)]
        source.ax = [ax(1, focused: true), ax(2)]
        var activated: WindowInfo?
        let defaults = UserDefaults(suiteName: "com.taber.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let panel = SwitcherPanelController(); panel.model.isDemo = true
        let monitor = GlobalShortcutMonitor(windowManager: WindowManager(source: source), settings: settings,
            panelController: panel, initialState: .active, commandIsPressed: { false },
            activate: { activated = $0 })

        monitor.beginOrAdvanceCycle(reverse: false)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(activated?.windowServerID, 2)
    }

    func test72OverlayCallbackRunsOncePerCycleBeforePresentation() async {
        let source = FixtureSource()
        source.raw = [window(), window(2)]
        var callbacks = 0
        let (monitor, _, _) = monitor(source)
        monitor.onCycleWillStart = { callbacks += 1 }

        monitor.beginOrAdvanceCycle(reverse: false)
        monitor.beginOrAdvanceCycle(reverse: false)
        XCTAssertEqual(callbacks, 1)
        monitor.cancelCycle()
        monitor.beginOrAdvanceCycle(reverse: false)
        XCTAssertEqual(callbacks, 2)
        monitor.cancelCycle()
    }

    func test73IndistinguishableCGOnlySurfacesCollapseToOneApplicationTarget() async {
        let source = FixtureSource()
        source.raw = [window(title: ""), window(2, title: "")]
        source.ax = []
        let manager = WindowManager(source: source)

        manager.refresh()

        XCTAssertEqual(manager.windows.count, 1,
            "Superfícies sem identidade individual defensável devem representar um único alvo de aplicativo")
        XCTAssertEqual(manager.windows.first?.activationMode, .activateApplication)
    }

    func test33RepeatablePerformanceFixture() async {
        let source = FixtureSource()
        source.raw = (1...200).map { window(UInt32($0)) }
        source.ax = (1...200).map { ax(UInt32($0), focused: $0 == 1) }
        let manager = WindowManager(source: source)
        let model = SwitcherViewModel()
        for _ in 0..<3 { manager.refresh() }
        let cpu = clock()
        var refreshSamplesMilliseconds: [Double] = []
        // A baseline 1.1.0 foi obtida com lotes de 40 varreduras + apresentação.
        // Medir cinco lotes iguais e comparar a mediana mantém a série histórica
        // comparável e reduz falsos positivos por uma única amostra ruidosa.
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<40 {
                manager.refresh()
                model.present(windows: manager.windows, selectedIndex: 1,
                    style: .icons, theme: .original, size: .medium)
            }
            refreshSamplesMilliseconds.append(
                (ProcessInfo.processInfo.systemUptime - start) / 40 * 1_000
            )
        }
        let medianRefreshMilliseconds = refreshSamplesMilliseconds.sorted()[refreshSamplesMilliseconds.count / 2]
        let baselineRefreshMilliseconds = 5.568
        let maximumAcceptedRefreshMilliseconds = baselineRefreshMilliseconds * 1.10
        let navigationStart = ProcessInfo.processInfo.systemUptime
        for i in 0..<10000 { model.select(index: i % 200) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("TABER_PERF refresh200_median_ms=\(medianRefreshMilliseconds) baseline_ms=\(baselineRefreshMilliseconds) limit_ms=\(maximumAcceptedRefreshMilliseconds) samples_ms=\(refreshSamplesMilliseconds) navigation10000_ms=\((ProcessInfo.processInfo.systemUptime - navigationStart) * 1000) cpu_ms=\(Double(clock() - cpu) / Double(CLOCKS_PER_SEC) * 1000) peakRSS_bytes=\(usage.ru_maxrss)")
        XCTAssertEqual(manager.windows.count, 200)
        XCTAssertLessThanOrEqual(medianRefreshMilliseconds, maximumAcceptedRefreshMilliseconds,
            "A mediana repetível de descoberta com 200 janelas regrediu mais de 10% contra a baseline documentada")
    }
}
