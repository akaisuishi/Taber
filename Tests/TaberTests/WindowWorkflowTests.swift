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
            title: String = "Documento", subrole: String = "AXStandardWindow", document: String = "") -> AccessibilityWindowSnapshot {
        AccessibilityWindowSnapshot(windowID: id, identifier: id.map(String.init) ?? "", title: title,
            document: document, subrole: subrole, bounds: rect, isMinimized: minimized,
            isMain: main, isFocused: focused, ordinal: Int(id ?? 0))
    }
    func manager(_ raw: [WindowInfo], _ snapshots: [AccessibilityWindowSnapshot]) -> (WindowManager, FixtureSource) {
        let source = FixtureSource(); source.raw = raw; source.ax = snapshots
        let manager = WindowManager(source: source); manager.refresh()
        return (manager, source)
    }
    func candidate(_ id: UInt32?, title: String = "Documento", ordinal: Int = 0) -> ActivationCandidate {
        ActivationCandidate(windowID: id, identifier: "", title: title, bounds: rect, isMinimized: false, ordinal: ordinal)
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
        XCTAssertEqual(m.frontmostWindow()?.id, 2)
    }
    func test04FocusedWindowWinsOverMainWindow() async {
        let (m, _) = manager([window(), window(2)], [ax(1, main: true), ax(2, focused: true)])
        XCTExpectFailure("S04: main is currently conflated with focused") { XCTAssertEqual(m.frontmostWindow()?.id, 2) }
    }
    func test05ChromeNormalAndIncognitoSelectExactIdentity() async {
        for id: UInt32 in [1, 2] {
            XCTAssertEqual(WindowMatchingPolicy.activationCandidateIndex(for: window(id, bundle: "com.google.Chrome"),
                in: [candidate(1), candidate(2)]), Int(id - 1))
        }
    }
    func test06SafariPrivateAndNormalRemainDistinct() async {
        let (m, _) = manager([window(bundle: "com.apple.Safari"), window(2, bundle: "com.apple.Safari")], [ax(1), ax(2)])
        XCTAssertEqual(m.windows.map(\.id), [1, 2])
    }
    func test07FinderEqualTitlesGetDistinctLabels() async {
        let (m, _) = manager([window(), window(2)], [ax(1), ax(2)])
        XCTAssertNotEqual(m.windows[0].displayTitle, m.windows[1].displayTitle)
    }
    func test08OverlappingWindowsSurviveAXUnavailable() async {
        let (m, _) = manager([window(), window(2)], [])
        XCTExpectFailure("S08: geometry-only fallback drops real windows") { XCTAssertEqual(m.windows.count, 2) }
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
        let c = WindowActivationCoordinator(clock: ManualActivationClock()) { $0.id == 1 ? a : b }
        c.activate(window(2, minimized: true))
        XCTAssertTrue(a.operations.isEmpty)
        XCTAssertTrue(b.operations.contains("restore"))
    }
    func test12OldRestoreCannotStealNewSelection() async {
        let clock = ManualActivationClock(), a = FixtureDriver(), b = FixtureDriver()
        let c = WindowActivationCoordinator(clock: clock) { $0.id == 1 ? a : b }
        c.activate(window(minimized: true)); c.activate(window(2))
        let before = a.operations.count; clock.advance()
        XCTExpectFailure("S12: delayed restoration is not cancelled") { XCTAssertEqual(a.operations.count, before) }
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
        XCTExpectFailure("S14: unresolved targets still activate the application") { XCTAssertFalse(d.operations.contains("activate")) }
    }
    func test15StaleWindowIDDoesNotMatchReplacementByGeometry() async {
        XCTExpectFailure("S15: known mismatching IDs still fall back to geometry") {
            XCTAssertNil(WindowMatchingPolicy.activationCandidateIndex(for: window(), in: [candidate(99)]))
        }
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
    }
    func test19SeparateDisplaySpacesHaveDistinctNumbers() async {
        let map = SpaceResolver.managedSpaceMap(from: [
            ["Display Identifier": "A", "Spaces": [["id64": 10, "type": 0]]],
            ["Display Identifier": "B", "Spaces": [["id64": 20, "type": 0]]]])
        XCTAssertNotEqual(map[10]?.number, map[20]?.number)
    }
    func test20SmallScreenMetricsStayFinite() async {
        for style in SwitcherStyle.allCases {
            let size = SwitcherPanelController.requestedSize(for: style, windows: [window()], metrics: .init(size: .compact), isSearching: true)
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertGreaterThan(size.width, 0)
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
            title: "Picture in Picture", bounds: rect, layer: 0, alpha: 1, isOnScreen: true, isHelperProcess: false)
        XCTAssertFalse(WindowEligibilityPolicy.allows(context, includeUtilityWindows: false))
        XCTAssertTrue(WindowEligibilityPolicy.allows(context, includeUtilityWindows: true))
    }
    func test25ModalDialogIdentityIsNotMergedByTitle() async {
        let (m, _) = manager([window(), window(2)], [ax(1), ax(2, focused: true, subrole: "AXDialog")])
        XCTAssertEqual(m.windows.count, 2)
        XCTAssertEqual(m.frontmostWindow()?.id, 2)
    }
    func test26BackgroundHelpersAreExcluded() async {
        for (bundle, policy, helper) in [("com.apple.Spotlight", NSApplication.ActivationPolicy.regular, false),
            ("com.google.drivefs", .accessory, false), ("com.fixture.helper", .regular, true)] {
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
        XCTAssertEqual(model.windows[model.selectedIndex].id, 2)
    }
    func test29SearchAccentsEmptyResultsAndDetachedCommand() async {
        let s = FixtureSource(); s.raw = [window(title: "Relatório"), window(2, title: "Notas")]; s.ax = [ax(1, title: "Relatório"), ax(2, title: "Notas")]
        let (m, p, _) = monitor(s)
        m.beginOrAdvanceCycle(reverse: false); m.enterSearch()
        m.handleSearchInput(keyCode: 0, text: "relatorio")
        XCTAssertEqual(p.model.windows.map(\.id), [1])
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
    }

    func test33RepeatablePerformanceFixture() async {
        let source = FixtureSource()
        source.raw = (1...200).map { window(UInt32($0)) }
        source.ax = (1...200).map { ax(UInt32($0), focused: $0 == 1) }
        let manager = WindowManager(source: source)
        let model = SwitcherViewModel()
        manager.refresh()
        let start = ProcessInfo.processInfo.systemUptime
        let cpu = clock()
        for _ in 0..<40 {
            manager.refresh()
            model.present(windows: manager.windows, selectedIndex: 1, style: .icons, theme: .original, size: .medium)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let navigationStart = ProcessInfo.processInfo.systemUptime
        for i in 0..<10000 { model.select(index: i % 200) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("TABER_PERF refresh200_ms=\(elapsed / 40 * 1000) navigation10000_ms=\((ProcessInfo.processInfo.systemUptime - navigationStart) * 1000) cpu_ms=\(Double(clock() - cpu) / Double(CLOCKS_PER_SEC) * 1000) peakRSS_bytes=\(usage.ru_maxrss)")
        XCTAssertEqual(manager.windows.count, 200)
    }
}
