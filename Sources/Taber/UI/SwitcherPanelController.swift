import AppKit
import Combine
import SwiftUI

@MainActor
final class SwitcherViewModel: ObservableObject {
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var style: SwitcherStyle = .preview
    @Published private(set) var theme: AppTheme = .original
    @Published private(set) var size: SwitcherSize = .medium
    @Published private(set) var searchQuery = ""
    @Published private(set) var isSearching = false
    @Published private(set) var isSearchDetached = false
    @Published private(set) var thumbnailGeneration: UInt = 0
    var isDemo = false
    var keepSearchOpen = true

    func present(
        windows: [WindowInfo],
        selectedIndex: Int,
        style: SwitcherStyle,
        theme: AppTheme,
        size: SwitcherSize
    ) {
        thumbnailGeneration &+= 1
        self.windows = windows
        self.selectedIndex = selectedIndex
        self.style = style
        self.theme = theme
        self.size = size
        searchQuery = ""
        isSearching = false
        isSearchDetached = false
    }

    func select(index: Int) {
        selectedIndex = index
    }

    func updateSearch(
        windows: [WindowInfo],
        selectedIndex: Int,
        query: String,
        isSearching: Bool
    ) {
        self.windows = windows
        self.selectedIndex = selectedIndex
        searchQuery = query
        self.isSearching = isSearching
        if !isSearching {
            isSearchDetached = false
        }
    }

    func setSearchDetached() {
        isSearchDetached = true
    }
}

@MainActor
final class SwitcherPanelController {
    let model = SwitcherViewModel()
    private let panel: NSPanel
    private var screenObserver: NSObjectProtocol?

    init() {
        let hostingController = NSHostingController(rootView: SwitcherView(model: model))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 720, height: 220)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentViewController = hostingController
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.resizeAndCenter(for: self.model.style, windows: self.model.windows,
                                     size: self.model.size, isSearching: self.model.isSearching)
            }
        }
    }

    func show(
        windows: [WindowInfo],
        selectedIndex: Int,
        style: SwitcherStyle,
        theme: AppTheme,
        size: SwitcherSize,
        isDemo: Bool = false,
        keepSearchOpen: Bool = true
    ) {
        // A demo e o ciclo real compartilham o mesmo painel. Encerrar a
        // apresentação anterior antes de publicar o novo modelo evita que
        // callbacks atrasados da demo escondam um ciclo real.
        panel.orderOut(nil)
        model.isDemo = isDemo
        model.keepSearchOpen = keepSearchOpen
        if !isDemo { WindowThumbnailService.shared.beginPresentation() }
        // Ajuste o frame ainda com o painel oculto. Publicar o novo conteúdo
        // antes do resize podia exibir por um instante o tamanho anterior.
        resizeAndCenter(for: style, windows: windows, size: size, isSearching: false)
        model.present(
            windows: windows,
            selectedIndex: selectedIndex,
            style: style,
            theme: theme,
            size: size
        )
        panel.level = .statusBar
        panel.orderFrontRegardless()
    }

    func update(selectedIndex: Int) {
        model.select(index: selectedIndex)
    }

    func beginSearch(
        windows: [WindowInfo],
        selectedIndex: Int,
        style: SwitcherStyle,
        size: SwitcherSize
    ) {
        resizeAndCenter(for: style, windows: windows, size: size, isSearching: true)
        model.updateSearch(
            windows: windows,
            selectedIndex: selectedIndex,
            query: "",
            isSearching: true
        )
    }

    func updateSearchResults(
        windows: [WindowInfo],
        selectedIndex: Int,
        query: String
    ) {
        model.updateSearch(
            windows: windows,
            selectedIndex: selectedIndex,
            query: query,
            isSearching: true
        )
    }

    func detachSearchFromCommand() {
        model.setSearchDetached()
    }

    func endSearch(
        windows: [WindowInfo],
        selectedIndex: Int,
        style: SwitcherStyle,
        size: SwitcherSize
    ) {
        resizeAndCenter(for: style, windows: windows, size: size, isSearching: false)
        model.updateSearch(
            windows: windows,
            selectedIndex: selectedIndex,
            query: "",
            isSearching: false
        )
    }

    func hide() {
        panel.orderOut(nil)
        panel.level = .normal
        model.isDemo = false
    }

    func hideDemo() {
        if model.isDemo { hide() }
    }

    var isShowingDemo: Bool {
        panel.isVisible && model.isDemo
    }

    private func resizeAndCenter(
        for style: SwitcherStyle,
        windows: [WindowInfo],
        size: SwitcherSize,
        isSearching: Bool
    ) {
        let metrics = SwitcherMetrics(size: size)
        let requestedSize = Self.requestedSize(
            for: style,
            windows: windows,
            metrics: metrics,
            isSearching: isSearching
        )

        let targetScreen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(origin: .zero, size: requestedSize)
        panel.setFrame(Self.fittedFrame(requested: requestedSize, visibleFrame: visibleFrame), display: true)
    }

    static func fittedFrame(requested: NSSize, visibleFrame: NSRect) -> NSRect {
        let fittedSize = NSSize(
            width: max(1, min(requested.width, visibleFrame.width - min(48, visibleFrame.width / 4))),
            height: max(1, min(requested.height, visibleFrame.height - min(48, visibleFrame.height / 4)))
        )
        let origin = NSPoint(
            x: visibleFrame.midX - fittedSize.width / 2,
            y: visibleFrame.midY - fittedSize.height / 2
        )
        return NSRect(origin: origin, size: fittedSize)
    }

    static func requestedSize(
        for style: SwitcherStyle,
        windows: [WindowInfo],
        metrics: SwitcherMetrics,
        isSearching: Bool
    ) -> NSSize {
        let count = max(windows.count, 1)
        let width: CGFloat
        let height: CGFloat

        switch style {
        case .preview:
            let visibleItems = min(count, 5)
            let itemWidth = metrics.previewCardWidth + (metrics.cardPadding * 2)
            width = (metrics.contentHorizontalPadding * 2)
                + (CGFloat(visibleItems) * itemWidth)
                + (CGFloat(max(visibleItems - 1, 0)) * metrics.itemSpacing)
            height = metrics.headerHeight + metrics.previewCardHeight + metrics.contentBottomPadding

        case .list:
            let widestText = windows.reduce(CGFloat.zero) { partial, window in
                max(
                    partial,
                    max(
                        measuredWidth(window.displayTitle, fontSize: metrics.listTitleFont, weight: .semibold),
                        measuredWidth(window.applicationName, fontSize: metrics.captionFont, weight: .regular)
                    )
                )
            }
            width = min(
                metrics.listMaximumWidth,
                max(metrics.listMinimumWidth, widestText + (205 * metrics.size.scale))
            )
            height = metrics.headerHeight
                + (CGFloat(min(count, 7)) * metrics.listRowHeight)
                + metrics.contentBottomPadding

        case .icons:
            let visibleItems = min(count, 7)
            let itemWidth = metrics.iconItemWidth + (metrics.cardPadding * 2)
            width = (metrics.contentHorizontalPadding * 2)
                + (CGFloat(visibleItems) * itemWidth)
                + (CGFloat(max(visibleItems - 1, 0)) * metrics.itemSpacing)
            height = metrics.headerHeight + metrics.iconBodyHeight + metrics.contentBottomPadding

        case .flow:
            let stageWidth = metrics.flowPreviewWidth(windowCount: count)
            let stageHeight = metrics.flowPreviewHeight(windowCount: count)
                + metrics.flowInformationHeight
            let queueVisibleRows = min(count, 6)
            let queueHeight = (48 * metrics.size.scale)
                + (CGFloat(queueVisibleRows) * metrics.flowQueueRowHeight)
                + (20 * metrics.size.scale)
            let showsQueue = count > 1
            width = (metrics.contentHorizontalPadding * 2)
                + stageWidth
                + (showsQueue ? metrics.itemSpacing + metrics.flowQueueWidth : 0)
            height = metrics.headerHeight
                + max(stageHeight, showsQueue ? queueHeight : 0)
                + metrics.contentBottomPadding
        }
        let outerMargin = metrics.panelOuterPadding * 2
        let searchHeight = isSearching ? metrics.searchBarHeight : 0
        let fittedWidth = isSearching ? max(width, metrics.searchMinimumWidth) : width
        return NSSize(
            width: ceil(fittedWidth + outerMargin),
            height: ceil(height + searchHeight + outerMargin)
        )
    }

    private static func measuredWidth(
        _ text: String,
        fontSize: CGFloat,
        weight: NSFont.Weight
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}
