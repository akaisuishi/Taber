import AppKit
import ApplicationServices
import XCTest

@MainActor
final class FixtureSource: WindowSnapshotSource {
    var complete = false
    var completenessOverride: Bool?
    func accessibilitySnapshotIsComplete(for pid: pid_t) -> Bool {
        completenessOverride ?? (complete || !(axByPID[pid] ?? ax).isEmpty)
    }
    var frontmostPID: pid_t? = 42
    var raw: [WindowInfo] = []
    var ax: [AccessibilityWindowSnapshot] = []
    var axByPID: [pid_t: [AccessibilityWindowSnapshot]] = [:]
    var locations: [CGWindowID: ResolvedWindowSpace] = [:]
    func candidates(includeUtilityWindows: Bool) -> [WindowInfo] { raw }
    func accessibilityWindows(for pid: pid_t, includeUtilityWindows: Bool) -> [AccessibilityWindowSnapshot] { axByPID[pid] ?? ax }
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
    var confirmationState: WindowActivationConfirmation = .pending
    func confirmation(of window: WindowInfo) -> WindowActivationConfirmation { exists ? confirmationState : .missing }
    var resolution: WindowResolution?
    var exists = true
    var isMinimized = true
    var operations: [String] = []
    func resolve(_ window: WindowInfo) -> WindowResolution { operations.append("resolve"); return resolution ?? (exists ? .found : .absent) }
    func restore() { operations.append("restore") }
    func focus() { operations.append("focus") }
    func activateApplication() { operations.append("activate") }
}

@MainActor
final class ApplicationFixtureDriver: WindowActivationDriving,
    ApplicationOnlyActivationDriving, ProcessValidatingActivationDriving {
    var confirmationState: WindowActivationConfirmation = .confirmed
    func confirmation(of window: WindowInfo) -> WindowActivationConfirmation { confirmationState }
    var processIsValid = true
    var applicationTargetIsValid = true
    var isMinimized = false
    var resolution: WindowResolution = .absent
    var operations: [String] = []

    func validateProcess(_ window: WindowInfo) -> Bool {
        operations.append("validate-process")
        return processIsValid
    }
    func validateApplicationTarget(_ window: WindowInfo) -> Bool {
        operations.append("validate-application")
        return applicationTargetIsValid
    }
    func resolve(_ window: WindowInfo) -> WindowResolution {
        operations.append("resolve")
        return resolution
    }
    func restore() { operations.append("restore") }
    func focus() { operations.append("focus") }
    func activateApplication() { operations.append("activate") }
}

@MainActor
final class WindowWorkflowTests: XCTestCase {
    let rect = CGRect(x: 20, y: 40, width: 800, height: 600)

    func window(_ id: UInt32 = 1, title: String = "Documento", minimized: Bool = false,
                onScreen: Bool? = nil,
                full: Bool = false, mode: WindowActivationMode = .raiseWindow,
                bundle: String = "com.apple.finder", pid: pid_t = 42) -> WindowInfo {
        WindowInfo(id: id, ownerPID: pid, bundleIdentifier: bundle, applicationName: "Fixture",
                   title: title, bounds: rect, isOnScreen: onScreen ?? !minimized, isMinimized: minimized,
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
    func test01aQuitSelectedApplicationDoesNotActivateItFirst() async {
        let source = FixtureSource()
        source.raw = [window(1), window(2, pid: 84)]
        source.ax = [ax(1, focused: true), ax(2)]
        let defaults = UserDefaults(suiteName: "com.taber.tests.quit.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let panel = SwitcherPanelController(); panel.model.isDemo = true
        var activated: WindowInfo?
        var terminated: WindowInfo?
        let monitor = GlobalShortcutMonitor(windowManager: WindowManager(source: source), settings: settings,
            panelController: panel, initialState: .active, commandIsPressed: { true },
            terminateApplication: { terminated = $0; return true }, activate: { activated = $0 })

        monitor.beginOrAdvanceCycle(reverse: false)
        let expected = panel.model.windows[panel.model.selectedIndex].id
        monitor.quitSelectedApplication()

        XCTAssertEqual(terminated?.id, expected)
        XCTAssertNil(activated)
        XCTAssertFalse(panel.isShowingDemo)
        monitor.handleCommandRelease()
        XCTAssertNil(activated)
    }
    func test01bQuitDuringColdCollectionCancelsInsteadOfActivating() async {
        let source = FixtureSource()
        source.raw = [window(1), window(2)]
        source.ax = [ax(1, focused: true), ax(2)]
        var publications: [@MainActor () -> Void] = []
        let manager = WindowManager(source: source, snapshotScheduler: { publications.append($0) })
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.taber.tests.quit-cold.\(UUID().uuidString)")!)
        let panel = SwitcherPanelController(); panel.model.isDemo = true
        var activated = false, terminated = false
        let monitor = GlobalShortcutMonitor(windowManager: manager, settings: settings, panelController: panel,
            initialState: .active, commandIsPressed: { true }, terminateApplication: { _ in terminated = true; return true },
            activate: { _ in activated = true })
        monitor.beginOrAdvanceCycle(reverse: false)
        XCTAssertFalse(publications.isEmpty)
        monitor.quitSelectedApplication()
        publications.removeFirst()()
        monitor.handleCommandRelease()
        XCTAssertFalse(activated)
        XCTAssertFalse(terminated)
    }
    func test01cQuitRejectsReusedPID() async {
        let birth = Date(timeIntervalSince1970: 100)
        let target = WindowInfo(id: 8, ownerPID: 80, bundleIdentifier: "com.fixture.target",
            applicationName: "Target", title: "", bounds: rect, isOnScreen: true, isMinimized: false,
            icon: nil, processLaunchDate: birth, activationPID: 81, activationProcessLaunchDate: birth)
        XCTAssertFalse(WindowMatchingPolicy.canTerminateApplication(expectedPID: target.activationPID,
            expectedBundleIdentifier: target.bundleIdentifier, expectedLaunchDate: target.activationProcessLaunchDate, actualPID: 81,
            actualBundleIdentifier: "com.fixture.target", actualLaunchDate: Date(timeIntervalSince1970: 101)))
        XCTAssertFalse(WindowMatchingPolicy.canTerminateApplication(expectedPID: target.activationPID,
            expectedBundleIdentifier: target.bundleIdentifier, expectedLaunchDate: target.activationProcessLaunchDate, actualPID: 81,
            actualBundleIdentifier: "com.other", actualLaunchDate: birth))
        XCTAssertTrue(WindowMatchingPolicy.canTerminateApplication(expectedPID: target.activationPID,
            expectedBundleIdentifier: target.bundleIdentifier, expectedLaunchDate: target.activationProcessLaunchDate, actualPID: 81,
            actualBundleIdentifier: "com.fixture.target", actualLaunchDate: birth))
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
    func test11aMinimizedApplicationOnlyTargetRestoresThroughAX() async {
        let driver = ApplicationFixtureDriver()
        driver.isMinimized = true
        driver.resolution = .found
        let minimizedRenderer = window(minimized: true, mode: .activateApplication)
        let result = WindowActivationCoordinator(clock: ManualActivationClock()) { _ in driver }
            .activate(minimizedRenderer)
        XCTAssertEqual(result.strategy, .accessibilityWindow)
        XCTAssertEqual(driver.operations, ["validate-process", "resolve", "restore", "focus", "activate"])
    }
    func test11bImmediateCommandMUsesCurrentAXMinimizedStateBeforeSnapshotRefresh() async {
        // The cycle snapshot still says visible, but AX has already observed
        // Command-M. Activation must restore the selected AX target instead
        // of treating its vanished CG surface as a closed window.
        let driver = FixtureDriver()
        driver.isMinimized = true
        let staleVisibleSnapshot = window(minimized: false)
        let result = WindowActivationCoordinator(clock: ManualActivationClock()) { _ in driver }
            .activate(staleVisibleSnapshot)
        XCTAssertEqual(result.outcome, .requested)
        XCTAssertEqual(driver.operations, ["resolve", "restore", "focus", "activate"])
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
        XCTAssertEqual(result.outcome, .requested)
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

        XCTAssertEqual(result.steps, [.targetResolved, .restored, .focusedAndRaised, .applicationActivated, .retryScheduled])
        XCTAssertEqual(driver.operations, ["resolve", "restore", "focus", "activate"])
        clock.advance()
        XCTAssertEqual(driver.operations,
            ["resolve", "restore", "focus", "activate", "resolve", "restore", "focus", "activate"])
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
        driver.confirmationState = .confirmed
        let result = WindowActivationCoordinator(clock: ManualActivationClock()) { _ in driver }
            .activate(protectedWindow)
        XCTAssertEqual(result.outcome, .requested)
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
        source.raw = [window(title: "", bundle: "com.game.renderer"), window(2, title: "", bundle: "com.game.renderer")]
        source.ax = []
        let manager = WindowManager(source: source)

        manager.refresh()

        XCTAssertEqual(manager.windows.count, 2,
            "IDs distintos sem título continuam sendo alvos distintos")
        XCTAssertEqual(manager.windows.first?.activationMode, .activateApplication)
    }

    func test74LeavingFullscreenSelectsWindowFromAnotherApplication() async {
        let source = FixtureSource()
        source.frontmostPID = 42
        source.raw = [
            window(1, title: "Tela cheia", full: true, pid: 42),
            window(2, title: "Destino", onScreen: false, pid: 84)
        ]
        // A janela de origem representa inclusive renderizadores fullscreen
        // sem uma árvore AX confiável; o PID em primeiro plano ainda deve
        // estabelecer o início correto do ciclo.
        source.ax = []
        var activated: WindowInfo?
        let defaults = UserDefaults(suiteName: "com.taber.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let panel = SwitcherPanelController(); panel.model.isDemo = true
        let monitor = GlobalShortcutMonitor(windowManager: WindowManager(source: source), settings: settings,
            panelController: panel, initialState: .active, commandIsPressed: { true },
            activate: { activated = $0 })

        monitor.beginOrAdvanceCycle(reverse: false)
        XCTAssertEqual(panel.model.windows.first?.windowServerID, 1)
        XCTAssertEqual(panel.model.windows[panel.model.selectedIndex].windowServerID, 2)
        monitor.finishCycle()

        XCTAssertEqual(activated?.windowServerID, 2)
        XCTAssertEqual(activated?.ownerPID, 84)
    }

    func test75OffscreenDestinationRetriesAfterFullscreenSpaceTransition() async {
        let driver = FixtureDriver()
        driver.isMinimized = false
        let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock) { _ in driver }

        let result = coordinator.activate(window(2, title: "Destino", onScreen: false, pid: 84))

        XCTAssertEqual(result.outcome, .requested)
        XCTAssertEqual(result.steps, [.targetResolved, .focusedAndRaised, .applicationActivated, .retryScheduled])
        XCTAssertEqual(driver.operations, ["resolve", "focus", "activate"])
        clock.advance()
        XCTAssertEqual(driver.operations, ["resolve", "focus", "activate", "resolve", "focus", "activate"])
    }

    func testFinderCompleteEmptySnapshotRemovesGhostEvenInBackground() async {
        let source = FixtureSource(); source.frontmostPID = 99; source.complete = true
        source.raw = [window()]
        let manager = WindowManager(source: source); manager.refresh()
        XCTAssertTrue(manager.windows.isEmpty)
        source.ax = [ax(1)]; manager.refresh()
        XCTAssertEqual(manager.windows.count, 1)
        source.ax = []; manager.refresh()
        XCTAssertTrue(manager.windows.isEmpty)
    }

    func testFinderIncompleteSnapshotPreservesRealCandidates() async {
        let source = FixtureSource(); source.raw = [window(), window(2, minimized: true)]
        let manager = WindowManager(source: source); manager.refresh()
        XCTAssertEqual(manager.windows.count, 2)
    }

    func testFinderDesktopAXSurfaceIsNotAWindow() async {
        let (manager, _) = manager([window()], [ax(1, subrole: "", role: "AXScrollArea")])
        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertFalse(WindowEligibilityPolicy.isUserAccessibilitySurface(
            bundleIdentifier: "com.apple.finder", role: "AXWindow", subrole: "AXUnknown"))
    }

    func testFinderConfirmedWindowsExcludeResidualSurface() async {
        let (manager, _) = manager([window(), window(2, minimized: true), window(3)],
            [ax(1), ax(2, minimized: true)])
        XCTAssertEqual(manager.windows.compactMap(\.windowServerID).sorted(), [1, 2])
        XCTAssertTrue(manager.windows.contains { $0.isMinimized })
    }

    func testCustomRendererSurvivesCompleteEmptyAXResponse() async {
        let source = FixtureSource(); source.complete = true
        source.raw = [window(bundle: "com.game.renderer")]
        let manager = WindowManager(source: source); manager.refresh()
        XCTAssertEqual(manager.windows.count, 1)
    }

    func testActivationWaitsForConfirmedDestinationAndStopsRetrying() async {
        let driver = FixtureDriver(); let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock) { _ in driver }
        var outcomes: [WindowActivationResult.Outcome] = []
        coordinator.onResult = { outcomes.append($0.outcome) }
        XCTAssertEqual(coordinator.activate(window()).outcome, .requested)
        clock.advance()
        driver.confirmationState = .confirmed
        let count = driver.operations.count
        clock.advance(); clock.advance()
        XCTAssertEqual(outcomes.last, .activated)
        XCTAssertEqual(driver.operations.count, count)
        XCTAssertTrue(clock.pending.isEmpty)
    }

    func testActivationTimeoutDoesNotReportSuccess() async {
        let driver = FixtureDriver(); let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock, now: { 0 }) { _ in driver }
        var result: WindowActivationResult?
        coordinator.onResult = { result = $0 }
        coordinator.activate(window())
        for _ in 0..<10 { clock.advance() }
        XCTAssertEqual(result?.outcome, .rejected(.timedOut))
        XCTAssertTrue(clock.pending.isEmpty)
    }

    func testClosedDestinationCancelsTransitionWithoutAnotherActivation() async {
        let driver = FixtureDriver(); let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock) { _ in driver }
        var result: WindowActivationResult?
        coordinator.onResult = { result = $0 }
        coordinator.activate(window()); driver.exists = false
        let count = driver.operations.count
        clock.advance()
        XCTAssertEqual(result?.outcome, .rejected(.targetNotFound))
        XCTAssertEqual(driver.operations.count, count)
    }

    func testNativeFullscreenComesFromAXWithoutGeometryGuess() async {
        var snapshot = ax(1); snapshot.isNativeFullScreen = true
        let (manager, _) = manager([window()], [snapshot])
        XCTAssertTrue(manager.windows[0].isFullScreen)
        XCTAssertEqual(manager.windows[0].activationMode, .raiseWindow)
    }

    func testBrowserPlayerKeepsHostAndPresentationIdentities() async {
        let (manager, _) = manager([window(1, bundle: "com.apple.Safari"),
            window(2, full: true, bundle: "com.apple.Safari")],
            [ax(1, document: "https://fixture/video"),
             ax(2, subrole: "AXDialog", document: "https://fixture/video")])
        XCTAssertEqual(manager.windows.count, 1)
        XCTAssertEqual(manager.windows[0].windowServerID, 1)
        XCTAssertEqual(manager.windows[0].presentationWindowID, 2)
    }

    func testAmbiguousBrowserPlayerDoesNotConsumeFocusedHost() async {
        let (manager, _) = manager([window(1, bundle: "com.apple.Safari"),
            window(2, bundle: "com.apple.Safari"), window(3, full: true, bundle: "com.apple.Safari")],
            [ax(1, focused: true), ax(2), ax(3, subrole: "AXDialog")])
        XCTAssertEqual(manager.windows.count, 3)
        XCTAssertFalse(manager.windows.contains { $0.presentationWindowID != nil })
    }

    func testTransparencyAmountMigratesPersistsAndClamps() async {
        let suite = "com.taber.tests.percent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "transparencyEnabled")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.transparencyEnabled)
        XCTAssertEqual(settings.transparencyPercent, 15)
        settings.transparencyPercent = 42
        XCTAssertEqual(SettingsStore(defaults: defaults).transparencyPercent, 42)
        settings.transparencyPercent = 100
        XCTAssertEqual(settings.transparencyPercent, 60)
        XCTAssertEqual(SettingsStore(defaults: defaults).transparencyPercent, 60)
        settings.transparencyPercent = .nan
        XCTAssertEqual(settings.transparencyPercent, 15)
        XCTAssertEqual(TaberTransparencyPolicy.normalizedPercent(-5), 0)
        XCTAssertEqual(TaberTransparencyPolicy.normalizedPercent(12.6), 13)
    }

    func testTransparencyOpacityAndAccessibilityPrecedence() async {
        for (percent, expected) in [(0.0, 1.0), (15.0, 0.85), (60.0, 0.4)] {
            XCTAssertEqual(TaberTransparencyPolicy.tintOpacity(percent: percent,
                userEnabled: true, reduceTransparency: false), expected, accuracy: 0.001)
            XCTAssertEqual(TaberTransparencyPolicy.tintOpacity(percent: percent,
                userEnabled: true, reduceTransparency: true), 1)
            XCTAssertEqual(TaberTransparencyPolicy.tintOpacity(percent: percent,
                userEnabled: false, reduceTransparency: false), 1)
        }
    }

    func testOpenSwitcherReceivesTransparencyChangesWithoutResettingSelection() async {
        let source = FixtureSource(); source.raw = [window(), window(2)]; source.ax = [ax(1), ax(2)]
        let (monitor, panel, settings) = monitor(source)
        monitor.beginOrAdvanceCycle(reverse: false)
        let index = panel.model.selectedIndex
        settings.transparencyEnabled = true; settings.transparencyPercent = 60
        XCTAssertTrue(panel.model.transparencyEnabled)
        XCTAssertEqual(panel.model.transparencyPercent, 60)
        XCTAssertEqual(panel.model.selectedIndex, index)
        monitor.cancelCycle()
    }

    func testSettingsWindowStaysOpaqueWhenTransparencyChanges() async {
        let (monitor, _, settings) = monitor(FixtureSource())
        let controller = SettingsWindowController(settings: settings, monitor: monitor,
            onRequestAccessibility: {}, onRequestScreenRecording: {}, onPreviewStyle: { _ in })
        settings.transparencyEnabled = true; settings.transparencyPercent = 60
        XCTAssertEqual(controller.window?.isOpaque, true)
        XCTAssertEqual(controller.window?.titlebarAppearsTransparent, false)
    }

    func testQuickMenuFitsSmallAndOffsetDisplays() async {
        for frame in [NSRect(x: 0, y: 0, width: 640, height: 360),
                      NSRect(x: -1280, y: -720, width: 1280, height: 680),
                      NSRect(x: 1710, y: 400, width: 1920, height: 1000)] {
            let anchor = NSRect(x: frame.maxX - 30, y: frame.maxY, width: 22, height: 24)
            let size = QuickSettingsLayout.availableSize(anchor: anchor, visibleFrame: frame)
            XCTAssertLessThanOrEqual(size.width, frame.width - 16)
            XCTAssertLessThanOrEqual(size.height + 24, frame.height)
            let layout = QuickSettingsLayout(); layout.maximumSize = size; layout.contentHeight = 1200
            XCTAssertEqual(layout.viewportSize.height, size.height)
            layout.contentHeight = 100
            XCTAssertEqual(layout.viewportSize.height, 100)
        }
    }

    func testTransientFirstResolutionRetriesBeforeAnyActivation() async {
        let driver = FixtureDriver(); driver.resolution = .temporarilyUnavailable
        let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock, now: { 0 }) { _ in driver }
        var last: WindowActivationResult?
        coordinator.onResult = { last = $0 }
        XCTAssertEqual(coordinator.activate(window()).outcome, .requested)
        XCTAssertEqual(driver.operations, ["resolve"])
        driver.resolution = .found; clock.advance()
        XCTAssertEqual(driver.operations, ["resolve", "resolve", "restore", "focus", "activate"])
        driver.confirmationState = .confirmed; clock.advance()
        XCTAssertEqual(last?.outcome, .activated)
    }

    func testAmbiguousResolutionNeverActivatesSibling() async {
        let driver = FixtureDriver(); driver.resolution = .ambiguous
        let coordinator = WindowActivationCoordinator(clock: ManualActivationClock()) { _ in driver }
        XCTAssertEqual(coordinator.activate(window()).outcome, .rejected(.ambiguousTarget))
        XCTAssertEqual(driver.operations, ["resolve"])
    }

    func testDeadlineStopsEvenIfTimerCountHasNotBeenExhausted() async {
        let driver = FixtureDriver(); driver.resolution = .temporarilyUnavailable
        let clock = ManualActivationClock(); var time: TimeInterval = 0
        let coordinator = WindowActivationCoordinator(clock: clock, now: { time }) { _ in driver }
        var last: WindowActivationResult?
        coordinator.onResult = { last = $0 }
        coordinator.activate(window()); time = 2.1; clock.advance()
        XCTAssertEqual(last?.outcome, .rejected(.timedOut))
        XCTAssertEqual(driver.operations, ["resolve"])
        XCTAssertTrue(clock.pending.isEmpty)
    }

    func testApplicationEvidenceIsNotReportedAsWindowFocus() async {
        let driver = FixtureDriver(); driver.confirmationState = .applicationActivated
        let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock) { _ in driver }
        var last: WindowActivationResult?
        coordinator.onResult = { last = $0 }
        coordinator.activate(window(mode: .activateApplication)); clock.advance()
        XCTAssertEqual(last?.outcome, .applicationActivated)
        XCTAssertEqual(last?.succeeded, false)
        XCTAssertTrue(clock.pending.isEmpty)
    }

    func testDiscoveryToActivationCGOnlyUsesApplicationStrategy() async {
        let (manager, _) = manager([window(71, bundle: "com.fixture.renderer")], [])
        guard let discovered = manager.windows.first else { return XCTFail("missing renderer") }
        XCTAssertEqual(discovered.activationMode, .activateApplication)
        let driver = ApplicationFixtureDriver(); let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock) { _ in driver }
        var last: WindowActivationResult?
        coordinator.onResult = { last = $0 }
        coordinator.activate(discovered); clock.advance()
        XCTAssertEqual(last?.outcome, .activated)
        XCTAssertFalse(driver.operations.contains("resolve"))
        XCTAssertFalse(driver.operations.contains("restore"))
    }

    func testHelperHostIsRecognizedAsCurrentWindow() async {
        let source = FixtureSource(); source.frontmostPID = 42
        source.raw = [WindowInfo(id: 901, ownerPID: 84, bundleIdentifier: "com.fixture.host",
            applicationName: "Host", title: "Renderer", bounds: rect, isOnScreen: true,
            isMinimized: false, icon: nil, activationPID: 42)]
        let manager = WindowManager(source: source); manager.refresh()
        XCTAssertEqual(manager.frontmostWindow()?.windowServerID, 901)
    }

    func testRecencyUsesObservedWindowFocusAcrossApplications() async {
        let history = WindowRecencyHistory()
        let a = window(1), b = window(2), c = window(3, pid: 84)
        history.touch(b.id); history.touch(c.id); history.touch(a.id)
        XCTAssertEqual(history.ordered([a,b,c], current: a).map(\.id), [a.id,c.id,b.id])
        history.purge(keeping: [a.id,b.id])
        XCTAssertEqual(history.ordered([a,b,c], current: a).map(\.id), [a.id,b.id,c.id])
    }

    func testObservedMouseFocusOverridesStaleSnapshotAndRejectsRestartedProcess() async {
        let history = WindowRecencyHistory()
        let a = window(1), b = window(2)
        history.observe(pid: 42, birth: nil, windowID: 2, windows: [a,b])
        XCTAssertEqual(history.current(in: [a,b], frontmostPID: 42, launchDate: nil)?.id, b.id)
        XCTAssertNil(history.current(in: [a,b], frontmostPID: 84, launchDate: nil))
        XCTAssertNil(history.current(in: [a,b], frontmostPID: 42, launchDate: Date()))
        XCTAssertNil(history.current(in: [a], frontmostPID: 42, launchDate: nil))
    }

    func testOpenCycleKeepsOrderAndCancelsWhenSelectedWindowCloses() async {
        let source = FixtureSource(); source.raw = [window(), window(2), window(3)]
        source.ax = [ax(1, focused: true), ax(2), ax(3)]
        let manager = WindowManager(source: source)
        let defaults = UserDefaults(suiteName: "com.taber.tests.freeze.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults); let panel = SwitcherPanelController(); panel.model.isDemo = true
        var activated = false
        let monitor = GlobalShortcutMonitor(windowManager: manager, settings: settings, panelController: panel,
            initialState: .active, commandIsPressed: { true }, activate: { _ in activated = true })
        monitor.beginOrAdvanceCycle(reverse: false)
        source.raw.reverse(); manager.refresh()
        XCTAssertEqual(panel.model.windows.compactMap(\.windowServerID), [1,2,3])
        XCTAssertEqual(panel.model.windows[panel.model.selectedIndex].windowServerID, 2)
        source.raw = [window(),window(3)]; source.ax = [ax(1),ax(3)]
        manager.refresh(); monitor.finishCycle()
        XCTAssertFalse(activated)
    }

    func testAXReferenceCacheKeysIncludeProcessBirthAndWindowID() async {
        let cache = AXWindowReferenceCache()
        let element = AXUIElementCreateApplication(42)
        let date = Date(timeIntervalSince1970: 100)
        cache.store(element, ownerPID: 42, launchDate: date, windowID: 1)
        XCTAssertNotNil(cache.element(ownerPID: 42, launchDate: date, windowID: 1))
        XCTAssertNil(cache.element(ownerPID: 42, launchDate: date.addingTimeInterval(1), windowID: 1))
        XCTAssertNil(cache.element(ownerPID: 84, launchDate: date, windowID: 1))
        cache.retain(liveWindows: [1], processes: [42: date.addingTimeInterval(1)])
        XCTAssertNil(cache.element(ownerPID: 42, launchDate: date, windowID: 1))

        cache.store(element, ownerPID: 77, launchDate: nil, windowID: 9)
        XCTAssertNotNil(cache.element(ownerPID: 77, launchDate: nil, windowID: 9))
        XCTAssertNil(cache.element(ownerPID: 77, launchDate: date, windowID: 9))
        cache.retain(liveWindows: [9], processes: [77: nil])
        XCTAssertNotNil(cache.element(ownerPID: 77, launchDate: nil, windowID: 9))
        cache.retain(liveWindows: [9], processes: [:])
        XCTAssertNil(cache.element(ownerPID: 77, launchDate: nil, windowID: 9))
    }

    func testIncompleteRefreshPreservesKnownAXActivationAndRevalidatesThroughCoordinator() async {
        let (manager, source) = manager([window(bundle: "com.taber.fixture")],
            [ax(1, focused: true, identifier: "document", ordinal: 0)])
        source.ax = []
        manager.refresh()
        let target = manager.windows[0]
        XCTAssertEqual(target.activationMode, .raiseWindow)
        XCTAssertEqual(target.accessibilityIdentifier, "document")
        XCTAssertEqual(target.accessibilityOrdinal, 0)
        XCTAssertFalse(target.isAccessibilityFocused, "Failed refresh must not recycle stale focus evidence")
        let driver = FixtureDriver()
        driver.isMinimized = false
        driver.confirmationState = .confirmed
        let coordinator = WindowActivationCoordinator(clock: ManualActivationClock(), driver: { _ in driver })
        coordinator.activate(target)
        XCTAssertTrue(driver.operations.contains("resolve"))
        XCTAssertTrue(driver.operations.contains("focus"))
    }

    func testIncompleteRefreshRetainsKnownUntitledOffSpaceAXWindow() async {
        let original = window(title: "", onScreen: false, bundle: "com.taber.fixture")
        let (manager, source) = manager([original], [ax(1, title: "", identifier: "", ordinal: 0)])
        source.ax = []
        manager.refresh()
        XCTAssertEqual(manager.windows.map(\.id), [original.id])
        XCTAssertEqual(manager.windows.first?.activationMode, .raiseWindow)
        XCTAssertEqual(manager.windows.first?.accessibilityOrdinal, 0)
    }

    func testCompletedEmptyAXRefreshDoesNotRetainPriorStrongStrategy() async {
        let (manager, source) = manager([window(bundle: "com.taber.fixture")], [ax(1)])
        source.ax = []
        source.complete = true
        manager.refresh()
        XCTAssertEqual(manager.windows.first?.activationMode, .activateApplication)
    }

    func testIncompleteRefreshDoesNotPromoteUnknownCGWindowOrRestartedProcess() async {
        func processWindow(_ birth: Date, _ id: CGWindowID = 1) -> WindowInfo {
            WindowInfo(id: id, ownerPID: 42, bundleIdentifier: "com.taber.fixture",
                applicationName: "Fixture", title: "Documento", bounds: rect,
                isOnScreen: true, isMinimized: false, icon: nil, processLaunchDate: birth)
        }
        let birth = Date(timeIntervalSince1970: 100)
        let (manager, source) = manager([processWindow(birth)], [ax(1)])
        source.ax = []
        source.raw = [processWindow(birth, 2), processWindow(birth.addingTimeInterval(1))]
        manager.refresh()
        XCTAssertEqual(manager.windows.count, 2)
        XCTAssertTrue(manager.windows.allSatisfy { $0.activationMode == .activateApplication })
        XCTAssertTrue(manager.windows.allSatisfy { $0.accessibilityOrdinal == nil })
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

extension WindowWorkflowTests {
    private func coldSearchMonitor(keepOpen: Bool = true) -> (
        GlobalShortcutMonitor, SwitcherPanelController, () -> Void, () -> WindowInfo?, () -> Int
    ) {
        let source = FixtureSource()
        source.raw = [window(1, title: "Alpha"), window(2, title: "Beta"), window(3, title: "Beta Two")]
        source.ax = [ax(1, focused: true, title: "Alpha"), ax(2, title: "Beta"), ax(3, title: "Beta Two")]
        var publications: [@MainActor () -> Void] = []
        let manager = WindowManager(source: source, snapshotScheduler: { publications.append($0) })
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.taber.tests.\(UUID().uuidString)")!)
        settings.keepSearchOpen = keepOpen
        settings.switcherStyle = .list
        let panel = SwitcherPanelController(); panel.model.isDemo = true
        var activated: WindowInfo?
        var starts = 0
        let monitor = GlobalShortcutMonitor(windowManager: manager, settings: settings,
            panelController: panel, initialState: .active, commandIsPressed: { true }, activate: { activated = $0 })
        monitor.onCycleWillStart = { starts += 1 }
        return (monitor, panel, {
            XCTAssertFalse(publications.isEmpty, "Cold path must await real WindowManager publication")
            if !publications.isEmpty { publications.removeFirst()() }
        }, { activated }, { starts })
    }

    func testColdSearchRetainsInputDeleteNavigationAndDetachedRelease() async {
        let (monitor, panel, publish, activated, starts) = coldSearchMonitor()
        monitor.beginOrAdvanceCycle(reverse: false)
        XCTAssertTrue(panel.model.windows.isEmpty)
        monitor.enterSearch()
        monitor.handleSearchInput(keyCode: 0, text: "Betax")
        monitor.handleSearchInput(keyCode: 51, text: "")
        monitor.handleCommandRelease()
        monitor.moveSearchSelection(reverse: false)
        await Task.yield()
        publish()
        XCTAssertEqual(starts(), 1)
        XCTAssertTrue(panel.model.isSearching)
        XCTAssertTrue(panel.model.isSearchDetached)
        XCTAssertEqual(panel.model.searchQuery, "Beta")
        XCTAssertEqual(panel.model.windows.compactMap(\.windowServerID), [2, 3])
        XCTAssertEqual(panel.model.selectedIndex, 1)
        XCTAssertNil(activated())
        monitor.handleSearchInput(keyCode: 36, text: "")
        XCTAssertEqual(activated()?.windowServerID, 3)
    }

    func testColdSearchReleaseCommitsFilteredTargetWhenKeepOpenDisabled() async {
        let (monitor, _, publish, activated, _) = coldSearchMonitor(keepOpen: false)
        monitor.beginOrAdvanceCycle(reverse: false)
        monitor.enterSearch()
        monitor.handleSearchInput(keyCode: 0, text: "Alpha")
        monitor.handleCommandRelease()
        await Task.yield()
        publish()
        XCTAssertEqual(activated()?.windowServerID, 1)
    }

    func testColdSearchReturnCommitsOnlyBufferedInput() async {
        let (monitor, _, publish, activated, _) = coldSearchMonitor()
        monitor.beginOrAdvanceCycle(reverse: false)
        monitor.enterSearch()
        monitor.handleSearchInput(keyCode: 0, text: "Alpha")
        monitor.handleSearchInput(keyCode: 36, text: "")
        monitor.handleSearchInput(keyCode: 0, text: "ignored after commit")
        await Task.yield()
        publish()
        XCTAssertEqual(activated()?.windowServerID, 1)
    }

    func testColdSearchEscapeExitsSearchAndSecondEscapeCancelsPublication() async {
        let (monitor, panel, publish, activated, _) = coldSearchMonitor()
        monitor.beginOrAdvanceCycle(reverse: false)
        monitor.enterSearch()
        monitor.handleSearchInput(keyCode: 0, text: "Alpha")
        monitor.handleEscape()
        await Task.yield()
        publish()
        XCTAssertFalse(panel.model.isSearching)
        XCTAssertEqual(panel.model.windows.count, 3)
        monitor.cancelCycle()
        XCTAssertNil(activated())

        let (cancelled, cancelledPanel, publishCancelled, cancelledActivation, _) = coldSearchMonitor()
        cancelled.beginOrAdvanceCycle(reverse: false)
        cancelled.enterSearch()
        cancelled.handleEscape()
        cancelled.handleEscape()
        await Task.yield()
        publishCancelled()
        XCTAssertTrue(cancelledPanel.model.windows.isEmpty)
        XCTAssertNil(cancelledActivation())
    }

    func testColdDoubleShiftSearchDetachedEscapeCancelsAndAllowsNextCycle() async {
        let (monitor, panel, publish, activated, _) = coldSearchMonitor()
        monitor.beginOrAdvanceCycle(reverse: false)
        monitor.handleSearchShiftPress()
        monitor.handleSearchShiftPress()
        monitor.handleSearchInput(keyCode: 0, text: "Beta")
        monitor.handleCommandRelease()
        monitor.handleEscape()
        await Task.yield()
        publish()
        XCTAssertTrue(panel.model.windows.isEmpty)
        XCTAssertNil(activated())
        monitor.beginOrAdvanceCycle(reverse: false)
        XCTAssertFalse(panel.model.isSearching)
        XCTAssertFalse(panel.model.isSearchDetached)
        monitor.cancelCycle()
    }
}


extension WindowWorkflowTests {
    func testColdCommandReleaseKeepsActivationAliveThroughConfirmation() async {
        let source = FixtureSource(); source.raw = [window(1), window(2)]
        source.ax = [ax(1, focused: true), ax(2)]
        var publications: [@MainActor () -> Void] = []
        let manager = WindowManager(source: source, snapshotScheduler: { publications.append($0) })
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.taber.tests.coldCommit.\(UUID().uuidString)")!)
        let panel = SwitcherPanelController(); panel.model.isDemo = true
        let clock = ManualActivationClock(), driver = FixtureDriver()
        let coordinator = WindowActivationCoordinator(clock: clock, driver: { _ in driver })
        var outcome: WindowActivationResult.Outcome?
        coordinator.onResult = { outcome = $0.outcome }
        let monitor = GlobalShortcutMonitor(windowManager: manager, settings: settings, panelController: panel,
            initialState: .active, commandIsPressed: { true },
            cancelPendingActivation: { coordinator.cancelPending() }, activate: { coordinator.activate($0) })
        monitor.beginOrAdvanceCycle(reverse: false)
        monitor.handleCommandRelease()
        XCTAssertFalse(publications.isEmpty)
        publications.removeFirst()()
        XCTAssertEqual(outcome, .requested)
        driver.confirmationState = .confirmed
        clock.advance()
        XCTAssertEqual(outcome, .activated)
    }
}


extension WindowWorkflowTests {
    func testThumbnailOverflowWaitsAndContinuesWhenSlotReleased() async {
        let queue = ThumbnailCaptureQueue(limit: 1)
        let token = queue.token
        let first = await queue.acquire(token)
        XCTAssertTrue(first)
        var resumed = false
        let next = Task { let granted = await queue.acquire(token); resumed = granted; return granted }
        await Task.yield()
        XCTAssertFalse(resumed)
        queue.release()
        let granted = await next.value
        XCTAssertTrue(granted)
        queue.release()
    }

    func testThumbnailNewPresentationDiscardsQueuedOldWorkWithoutOverbooking() async {
        let queue = ThumbnailCaptureQueue(limit: 1)
        let old = queue.token
        let acquired = await queue.acquire(old)
        XCTAssertTrue(acquired)
        let obsolete = Task { await queue.acquire(old) }
        await Task.yield()
        queue.begin()
        let oldGranted = await obsolete.value
        XCTAssertFalse(oldGranted)
        var entered = false
        let next = Task { let granted = await queue.acquire(queue.token); entered = granted; return granted }
        await Task.yield()
        XCTAssertFalse(entered)
        queue.release()
        let newGranted = await next.value
        XCTAssertTrue(newGranted)
        queue.release()
    }
}


extension WindowWorkflowTests {
    func testThumbnailRequestIdentityIncludesPlayerAndQuantizesLayout() async {
        let host = window(1), player = window(1).withPresentation(windowID: 9)
        let size = CGSize(width: 320, height: 180)
        XCTAssertNotEqual(WindowThumbnailService.requestKey(host, size), WindowThumbnailService.requestKey(player, size))
        XCTAssertEqual(WindowThumbnailService.requestKey(host, CGSize(width: 319.1, height: 180)), WindowThumbnailService.requestKey(host, size))
    }
}

extension WindowWorkflowTests {
    func testThumbnailServiceCoalescesAndReusesFreshImages() async throws {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        var captures = 0
        var time: TimeInterval = 0
        var permitted = true
        let service = WindowThumbnailService(permission: { permitted }, now: { time }, capture: { _, _ in
            captures += 1
            try await Task.sleep(for: .milliseconds(10))
            return image
        })
        let target = window(), size = CGSize(width: 320, height: 180)
        let first = Task { await service.thumbnail(for: target, targetSize: size, generation: 0) }
        let second = Task { await service.thumbnail(for: target, targetSize: size, generation: 0) }
        _ = await first.value; _ = await second.value
        XCTAssertEqual(captures, 1)
        for _ in 0..<100 { _ = await service.thumbnail(for: target, targetSize: size, generation: 1) }
        XCTAssertEqual(captures, 1, "Warm reads must not capture again")
        time = 2
        XCTAssertNotNil(service.cachedThumbnail(for: target, targetSize: size))
        _ = await service.thumbnail(for: target, targetSize: size, generation: 2)
        XCTAssertEqual(captures, 2)
        time = 33
        XCTAssertNil(service.cachedThumbnail(for: target, targetSize: size))
        permitted = false
        if case .permissionRequired = await service.thumbnail(for: target, targetSize: size, generation: 3) {} else { XCTFail("Permission must override cached image") }
    }

    func testThumbnailServiceEventuallyCapturesEveryOverflowRequest() async {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        var active = 0, peak = 0, completed = 0
        let service = WindowThumbnailService(permission: { true }, capture: { _, _ in
            active += 1; peak = max(peak, active)
            try await Task.sleep(for: .milliseconds(5))
            active -= 1; completed += 1
            return image
        })
        let tasks = (1...12).map { id in
            Task { await service.thumbnail(for: window(UInt32(id)), targetSize: CGSize(width: 320, height: 180), generation: 0) }
        }
        for task in tasks { if case .image = await task.value {} else { XCTFail("Overflow must wait rather than lose its image") } }
        XCTAssertEqual(completed, 12)
        XCTAssertLessThanOrEqual(peak, 3)
    }
}


extension WindowWorkflowTests {
    func testMissingCatalogEntriesDoNotOccupyScreenshotSlots() async {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        var waiting: [CheckedContinuation<Void, Never>] = []
        let prepared = expectation(description: "Three catalog lookups waiting")
        prepared.expectedFulfillmentCount = 3
        let service = WindowThumbnailService(permission: { true }, prepare: { window in
            if window.windowServerID != 4 {
                await withCheckedContinuation { continuation in waiting.append(continuation); prepared.fulfill() }
            }
        }, capture: { _, _ in image })
        let tasks = (1...3).map { id in Task { await service.thumbnail(for: window(UInt32(id)), targetSize: CGSize(width: 320, height: 180), generation: 0) } }
        await fulfillment(of: [prepared], timeout: 1)
        let available = expectation(description: "Available window captured while catalogs wait")
        let fourth = Task {
            if case .image = await service.thumbnail(for: window(4), targetSize: CGSize(width: 320, height: 180), generation: 0) { available.fulfill() }
        }
        await fulfillment(of: [available], timeout: 1)
        for continuation in waiting { continuation.resume() }
        for task in tasks { _ = await task.value }
        _ = await fourth.value
    }
}


extension WindowWorkflowTests {
    func testSafariResidualFullscreenSurfaceCannotHijackNormalHost() async {
        let host = window(1769, bundle: "com.apple.Safari")
        let residual = WindowInfo(id: 1985, ownerPID: 42, bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari", title: "", bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            isOnScreen: false, isMinimized: false, icon: nil)
        let (manager, source) = manager([host, residual], [ax(1769, focused: true)])
        XCTAssertEqual(manager.windows.count, 1)
        XCTAssertEqual(manager.windows[0].windowServerID, 1769)
        XCTAssertNil(manager.windows[0].presentationWindowID)
        XCTAssertFalse(manager.windows[0].isFullScreen)
        XCTAssertEqual(manager.windows[0].activationMode, .raiseWindow)
        let driver = FixtureDriver(); driver.isMinimized = false
        let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock, driver: { _ in driver })
        coordinator.activate(manager.windows[0])
        XCTAssertEqual(driver.operations, ["resolve", "focus", "activate"])
        source.completenessOverride = false
        manager.refresh()
        let incompleteHost = manager.windows.first { $0.windowServerID == 1769 }!
        XCTAssertNil(incompleteHost.presentationWindowID)
        XCTAssertFalse(incompleteHost.isFullScreen)
        XCTAssertEqual(incompleteHost.activationMode, .raiseWindow)
        source.completenessOverride = true
        // A complete refresh after the residual disappears keeps the same target.
        source.raw = [host]; manager.refresh()
        XCTAssertEqual(manager.windows[0].id, host.id)
    }

    func testConfirmedCGOnlyFullscreenPlayerNeverReplacesVisibleSafariHost() async {
        let source = FixtureSource()
        source.raw = [window(1, bundle: "com.apple.Safari"), window(2, full: true, bundle: "com.apple.Safari")]
        source.ax = [ax(1, focused: true)]
        source.locations = [2: ResolvedWindowSpace(identifier: 90, number: nil, isFullScreen: true)]
        let manager = WindowManager(source: source); manager.refresh()
        let host = manager.windows.first { $0.windowServerID == 1 }!
        XCTAssertFalse(host.isFullScreen)
        XCTAssertNil(host.presentationWindowID)
        XCTAssertEqual(host.activationMode, .raiseWindow)
        XCTAssertTrue(manager.windows.contains { $0.windowServerID == 2 && $0.isFullScreen })
    }

    func testActiveSafariFullscreenVideoTransfersFocusAndPrioritizesOtherAppsBeforeOffscreenHost() async {
        let source = FixtureSource()
        source.frontmostPID = 42
        let notchedPlayerBounds = CGRect(x: 0, y: 38, width: 1710, height: 1074)
        let host = WindowInfo(id: 126, ownerPID: 42, bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari", title: "YouTube", bounds: rect,
            isOnScreen: false, isMinimized: false, isFullScreen: false, icon: nil)
        let player = WindowInfo(id: 270, ownerPID: 42, bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari", title: "", bounds: notchedPlayerBounds,
            isOnScreen: true, isMinimized: false, isFullScreen: false, icon: nil)
        let otherApp = WindowInfo(id: 158, ownerPID: 84, bundleIdentifier: "com.google.antigravity",
            applicationName: "Antigravity", title: "Taber", bounds: rect,
            isOnScreen: false, isMinimized: false, isFullScreen: false, icon: nil)
        source.raw = [player, host, otherApp]
        source.axByPID = [
            42: [ax(126, focused: true, title: "YouTube")],
            84: [ax(158, title: "Taber")]
        ]
        source.locations = [
            126: ResolvedWindowSpace(identifier: 1, number: 1, isFullScreen: false),
            270: ResolvedWindowSpace(identifier: 58, number: nil, isFullScreen: true),
            158: ResolvedWindowSpace(identifier: 1, number: 1, isFullScreen: false)
        ]

        let manager = WindowManager(source: source)
        manager.refresh()

        let discoveredPlayer = manager.windows.first { $0.windowServerID == 270 }
        let discoveredHost = manager.windows.first { $0.windowServerID == 126 }
        XCTAssertNotNil(discoveredPlayer, "Detached fullscreen video surface in fullscreen Space must remain eligible")
        XCTAssertEqual(discoveredPlayer?.isFullScreen, true)
        XCTAssertEqual(discoveredPlayer?.presentationWindowID, 270)
        XCTAssertEqual(discoveredPlayer?.activationMode, .activateApplication)
        XCTAssertEqual(discoveredPlayer?.isAccessibilityFocused, true)
        XCTAssertEqual(discoveredHost?.isAccessibilityFocused, false)
        XCTAssertEqual(manager.frontmostWindow()?.windowServerID, 270)

        let history = WindowRecencyHistory()
        // Even if AX focus observation reported the host window ID (126), recency current()
        // must resolve to the on-screen fullscreen player (270) when the host is off-screen.
        history.observe(pid: 42, birth: nil, windowID: 126, windows: manager.windows)
        let current = history.current(in: manager.windows, frontmostPID: 42, launchDate: nil)
        XCTAssertEqual(current?.windowServerID, 270)

        let ordered = history.ordered(manager.windows, current: current)
        XCTAssertEqual(ordered.compactMap(\.windowServerID), [270, 158, 126],
            "Command+Tab from fullscreen video must select the other app before the off-screen browser host")
    }

    func testOffSpaceOmittedWindowActivatesOnlyWhenUnambiguousWhileIPCTimeoutNeverActivatesBlindly() async {
        // 1. Transient IPC failure (.temporarilyUnavailable) must NEVER activate blindly on retry.
        let ipcDriver = ApplicationFixtureDriver()
        ipcDriver.isMinimized = false
        ipcDriver.confirmationState = .pending
        ipcDriver.resolution = .temporarilyUnavailable
        let ipcClock = ManualActivationClock()
        let ipcCoordinator = WindowActivationCoordinator(clock: ipcClock, now: { 0 }) { _ in ipcDriver }
        let target = window(158, title: "Taber", onScreen: false, mode: .raiseWindow, pid: 84)

        XCTAssertEqual(ipcCoordinator.activate(target).outcome, .requested)
        ipcClock.advance()
        XCTAssertFalse(ipcDriver.operations.contains("activate"),
            "Transient AX IPC unavailability must never activate a potentially wrong sibling window")

        // 2. Proven sole off-Space window (.omittedOffSpace) activates on retry to trigger Space transition.
        let driver = ApplicationFixtureDriver()
        driver.isMinimized = false
        driver.confirmationState = .pending
        driver.resolution = .omittedOffSpace
        let clock = ManualActivationClock()
        let coordinator = WindowActivationCoordinator(clock: clock, now: { 0 }) { _ in driver }

        XCTAssertEqual(coordinator.activate(target).outcome, .requested)
        XCTAssertEqual(driver.operations, ["validate-process", "resolve"])

        clock.advance()
        XCTAssertEqual(driver.operations, ["validate-process", "resolve", "validate-process", "resolve", "validate-application", "activate"])

        driver.resolution = .found
        clock.advance()
        XCTAssertTrue(driver.operations.suffix(3).elementsEqual(["resolve", "focus", "activate"]))
    }

    func testConsolidatedPlayerPreservesSiblingRecencyAndDetachedPlayerDeprioritizesOnlyObservedHost() async {
        // 1. Consolidated AXDialog player (windowServerID != presentationWindowID) keeps sibling recency intact.
        let consolidatedCurrent = window(1, onScreen: true, full: true, bundle: "com.google.Chrome", pid: 42)
            .withPresentation(windowID: 2, isOnScreen: true)
            .withActivationMode(.raiseWindow)
        let secondChrome = window(3, onScreen: false, full: false, bundle: "com.google.Chrome", pid: 42)
        let otherApp = window(99, onScreen: false, full: false, bundle: "com.apple.TextEdit", pid: 84)
        let consolidatedHistory = WindowRecencyHistory()
        consolidatedHistory.touch(otherApp.id)
        consolidatedHistory.touch(secondChrome.id)
        consolidatedHistory.touch(consolidatedCurrent.id)
        let consolidatedOrder = consolidatedHistory.ordered(
            [consolidatedCurrent, otherApp, secondChrome],
            current: consolidatedCurrent
        )
        XCTAssertEqual(consolidatedOrder.compactMap(\.windowServerID), [1, 3, 99],
            "Consolidated player already absorbed its host and must not penalize other browser windows")

        // 2. Detached player (windowServerID == presentationWindowID) deprioritizes only the observed host (126).
        let detachedPlayer = window(270, onScreen: true, full: true, bundle: "com.apple.Safari", pid: 42)
            .withPresentation(windowID: 270, isOnScreen: true)
        let safariHost = window(126, onScreen: false, full: false, bundle: "com.apple.Safari", pid: 42)
        let safariOther = window(130, onScreen: false, full: false, bundle: "com.apple.Safari", pid: 42)
        let detachedHistory = WindowRecencyHistory()
        detachedHistory.touch(otherApp.id)
        detachedHistory.touch(safariOther.id)
        detachedHistory.observe(pid: 42, birth: nil, windowID: 126, windows: [detachedPlayer, safariHost, safariOther, otherApp])
        let current = detachedHistory.current(in: [detachedPlayer, safariHost, safariOther, otherApp], frontmostPID: 42, launchDate: nil)
        XCTAssertEqual(current?.windowServerID, 270)
        let detachedOrder = detachedHistory.ordered([detachedPlayer, safariHost, safariOther, otherApp], current: current)
        XCTAssertEqual(detachedOrder.compactMap(\.windowServerID), [270, 130, 99, 126],
            "Only the observed off-screen host (126) is deprioritized; independent browser window (130) keeps recency")
    }

    func testTrackingSnapshotPurgesClosedWindowIdentitiesFromRecencyHistory() async {
        let source = FixtureSource()
        let w1 = window(1, pid: 42), w2 = window(2, pid: 42), w3 = window(3, pid: 84)
        source.raw = [w1, w2, w3]
        source.axByPID = [42: [ax(1, focused: true), ax(2)], 84: [ax(3)]]
        let manager = WindowManager(source: source)
        let suite = "com.taber.tests.tracking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.shortcutEnabled = false
        let history = WindowRecencyHistory()
        let tracking = WindowTrackingService(manager: manager, settings: settings, history: history)
        _ = tracking

        manager.refresh()
        history.touch(w3.id)
        history.touch(w2.id)
        history.touch(w1.id)
        XCTAssertEqual(history.ordered([w1, w2, w3], current: w1).compactMap(\.windowServerID), [1, 2, 3])

        // Close w2 -> snapshot purges w2's stamp; if an identity were reintroduced later in test, its old stamp is gone.
        source.raw = [w1, w3]
        source.axByPID = [42: [ax(1, focused: true)], 84: [ax(3)]]
        manager.refresh()
        XCTAssertEqual(history.ordered([w1, w2, w3], current: w1).compactMap(\.windowServerID), [1, 3, 2])
    }

    func testNonBrowserWebViewAppDetachedFullscreenPlayerRemainsSwitchable() async {
        let source = FixtureSource()
        source.frontmostPID = 42
        let notchedPlayerBounds = CGRect(x: 0, y: 38, width: 1710, height: 1074)
        let host = WindowInfo(id: 501, ownerPID: 42, bundleIdentifier: "com.example.webview-player",
            applicationName: "WebViewApp", title: "Course Video", bounds: rect,
            isOnScreen: false, isMinimized: false, isFullScreen: false, icon: nil)
        let player = WindowInfo(id: 502, ownerPID: 42, bundleIdentifier: "com.example.webview-player",
            applicationName: "WebViewApp", title: "", bounds: notchedPlayerBounds,
            isOnScreen: true, isMinimized: false, isFullScreen: false, icon: nil)
        source.raw = [player, host]
        source.axByPID = [42: [ax(501, focused: true, title: "Course Video")]]
        source.locations = [
            501: ResolvedWindowSpace(identifier: 1, number: 1, isFullScreen: false),
            502: ResolvedWindowSpace(identifier: 77, number: nil, isFullScreen: true)
        ]

        let manager = WindowManager(source: source)
        manager.refresh()

        let discoveredPlayer = manager.windows.first { $0.windowServerID == 502 }
        XCTAssertNotNil(discoveredPlayer)
        XCTAssertEqual(discoveredPlayer?.isFullScreen, true)
        XCTAssertEqual(discoveredPlayer?.presentationWindowID, 502)
        XCTAssertEqual(discoveredPlayer?.activationMode, .activateApplication)
        XCTAssertEqual(discoveredPlayer?.isAccessibilityFocused, true)
    }

    func testUntitledAXFullScreenVideoPlayerDeprioritizesOffScreenHostWindow() {
        let previousApp = window(1799, title: "Fixture A", onScreen: false, full: false, bundle: "com.example.a", pid: 10)
        let wkHost = window(1842, title: "Fixture B", onScreen: false, full: false, bundle: "com.example.b", pid: 20)
        let wkFullScreenVideo = window(1844, title: "", onScreen: true, full: true, bundle: "com.example.b", pid: 20)
        let allWindows = [wkFullScreenVideo, wkHost, previousApp]
        let history = WindowRecencyHistory()
        history.touch(previousApp.id)
        history.touch(wkHost.id)
        history.observe(pid: 20, birth: nil, windowID: 1844, windows: allWindows)
        let current = history.current(in: allWindows, frontmostPID: 20, launchDate: nil)
        XCTAssertEqual(current?.windowServerID, 1844)
        let ordered = history.ordered(allWindows, current: current)
        XCTAssertEqual(ordered.compactMap(\.windowServerID), [1844, 1799, 1842],
            "Untitled WKFullScreenWindow must place the previous app ahead of its own off-screen host window")
    }
}
