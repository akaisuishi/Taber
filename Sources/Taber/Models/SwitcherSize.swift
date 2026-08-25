import CoreGraphics
import Foundation

enum SwitcherSize: String, CaseIterable, Identifiable {
    case compact
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compacto"
        case .medium: "Médio"
        case .large: "Grande"
        }
    }

    var description: String {
        switch self {
        case .compact: "Mais conteúdo, menos espaço."
        case .medium: "Equilíbrio entre leitura e agilidade."
        case .large: "Texto e alvos maiores para leitura confortável."
        }
    }

    var symbolName: String {
        switch self {
        case .compact: "textformat.size.smaller"
        case .medium: "textformat.size"
        case .large: "textformat.size.larger"
        }
    }

    var scale: CGFloat {
        switch self {
        case .compact: 0.84
        case .medium: 1
        case .large: 1.18
        }
    }
}

struct SwitcherMetrics {
    let size: SwitcherSize

    private var scale: CGFloat { size.scale }

    var panelOuterPadding: CGFloat { 4 }
    var panelCornerRadius: CGFloat { 22 * scale }
    var headerFont: CGFloat { 11 * scale }
    var headerHorizontalPadding: CGFloat { 18 * scale }
    var headerTopPadding: CGFloat { 13 * scale }
    var headerBottomPadding: CGFloat { 7 * scale }
    var headerHeight: CGFloat { 38 * scale }
    var searchBarHeight: CGFloat { 44 * scale }
    var searchMinimumWidth: CGFloat { 360 * scale }
    var contentHorizontalPadding: CGFloat { 14 * scale }
    var contentBottomPadding: CGFloat { 14 * scale }
    var itemSpacing: CGFloat { 12 * scale }
    var cardPadding: CGFloat { 9 * scale }
    var cardCornerRadius: CGFloat { 12 * scale }

    var titleFont: CGFloat { 13 * scale }
    var listTitleFont: CGFloat { 14 * scale }
    var flowTitleFont: CGFloat { 17 * scale }
    var captionFont: CGFloat { 11 * scale }
    var smallCaptionFont: CGFloat { 10 * scale }

    var previewCardWidth: CGFloat { 220 * scale }
    var previewHeight: CGFloat { 132 * scale }
    var previewCardHeight: CGFloat { previewHeight + (65 * scale) }

    var listIconSize: CGFloat { 38 * scale }
    var listRowHeight: CGFloat { 63 * scale }
    var listMinimumWidth: CGFloat { 390 * scale }
    var listMaximumWidth: CGFloat { 680 * scale }

    var iconSize: CGFloat { 58 * scale }
    var iconItemWidth: CGFloat { 96 * scale }
    var iconBodyHeight: CGFloat { 128 * scale }

    var flowPreviewWidth: CGFloat { 540 * scale }
    var flowPreviewHeight: CGFloat { 304 * scale }
    var flowQueueWidth: CGFloat { 310 * scale }
    var flowQueueRowHeight: CGFloat { 51 * scale }
    var flowInformationHeight: CGFloat { 60 * scale }

    func flowPreviewWidth(windowCount: Int) -> CGFloat {
        flowPreviewWidth * (windowCount == 1 ? 0.82 : 1)
    }

    func flowPreviewHeight(windowCount: Int) -> CGFloat {
        flowPreviewHeight * (windowCount == 1 ? 0.82 : 1)
    }
}
