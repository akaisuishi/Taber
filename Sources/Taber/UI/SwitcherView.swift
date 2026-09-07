import AppKit
import SwiftUI

struct SwitcherView: View {
    @ObservedObject var model: SwitcherViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var metrics: SwitcherMetrics { SwitcherMetrics(size: model.size) }
    private var palette: TaberThemePalette { model.theme.palette }

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearching { searchBar }
            if model.windows.isEmpty { emptyState }
            else if model.style == .flow { flow }
            else { sequence }
            footer
        }
        .background(TaberSurfaceBackground(color: palette.panel))
        .clipShape(RoundedRectangle(cornerRadius: metrics.panelCornerRadius))
        .overlay { RoundedRectangle(cornerRadius: metrics.panelCornerRadius).stroke(palette.border) }
        .padding(metrics.panelOuterPadding)
        .foregroundStyle(palette.primary)
        .environment(\.taberThemePalette, palette)
        .preferredColorScheme(model.theme.colorScheme)
        .accessibilityIdentifier("switcher.panel")
    }

    private var sequence: some View {
        ScrollViewReader { proxy in
            ScrollView(model.style == .list ? .vertical : .horizontal, showsIndicators: false) {
                if model.style == .list {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                            listRow(window, index: index).frame(height: metrics.listRowHeight).id(window.id)
                        }
                    }.padding(.horizontal, metrics.contentHorizontalPadding)
                } else {
                    LazyHStack(alignment: .top, spacing: metrics.itemSpacing) {
                        ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                            if model.style == .preview { previewCard(window, index: index).id(window.id) }
                            else { iconCard(window, index: index).id(window.id) }
                        }
                    }.padding(.horizontal, metrics.contentHorizontalPadding)
                }
            }
            .padding(.top, metrics.contentBottomPadding)
            .onAppear { scroll(proxy) }
            .onChange(of: model.selectedIndex) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard model.windows.indices.contains(model.selectedIndex) else { return }
        // Keyboard navigation must not queue animations behind fast repeats.
        proxy.scrollTo(model.windows[model.selectedIndex].id, anchor: .center)
    }

    private func previewCard(_ window: WindowInfo, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8 * model.size.scale) {
            thumbnail(window, index: index, width: metrics.previewCardWidth, height: metrics.previewHeight)
            Text(window.displayTitle).font(.system(size: metrics.titleFont, weight: .medium)).lineLimit(1)
            HStack(spacing: 5) {
                appIcon(window, size: 14 * model.size.scale)
                Text(window.applicationName).lineLimit(1)
                Spacer(minLength: 2)
                spaceLabel(window)
            }.font(.system(size: metrics.smallCaptionFont)).foregroundStyle(palette.secondary)
        }
        .frame(width: metrics.previewCardWidth)
        .padding(metrics.cardPadding)
        .background(TaberChoiceSurface(selected: index == model.selectedIndex))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(index == model.selectedIndex ? .isSelected : [])
    }

    private func iconCard(_ window: WindowInfo, index: Int) -> some View {
        VStack(spacing: 6 * model.size.scale) {
            appIcon(window, size: metrics.iconSize)
            Text(window.applicationName).font(.system(size: metrics.smallCaptionFont, weight: .medium)).lineLimit(1)
            Text(window.displayTitle).font(.system(size: metrics.smallCaptionFont)).foregroundStyle(palette.secondary).lineLimit(1)
            spaceLabel(window).font(.system(size: metrics.smallCaptionFont - 1)).foregroundStyle(palette.tertiary)
        }
        .frame(width: metrics.iconItemWidth)
        .padding(metrics.cardPadding)
        .background(TaberChoiceSurface(selected: index == model.selectedIndex))
        .help("\(window.displayTitle) · \(window.spaceDescription)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(index == model.selectedIndex ? .isSelected : [])
    }

    private func listRow(_ window: WindowInfo, index: Int) -> some View {
        HStack(spacing: 12 * model.size.scale) {
            appIcon(window, size: metrics.listIconSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(window.displayTitle).font(.system(size: metrics.listTitleFont, weight: .medium)).lineLimit(1)
                Text(window.applicationName).font(.system(size: metrics.captionFont)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            spaceLabel(window).font(.system(size: metrics.smallCaptionFont)).foregroundStyle(palette.secondary)
        }
        .padding(.horizontal, 12 * model.size.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaberChoiceSurface(selected: index == model.selectedIndex, radius: 8))
        .padding(.vertical, 2 * model.size.scale)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(index == model.selectedIndex ? .isSelected : [])
    }

    private var flow: some View {
        GeometryReader { geometry in
            let queueWidth = model.windows.count > 1 ? min(metrics.flowQueueWidth, geometry.size.width * 0.37) : 0
            let stageWidth = max(1, geometry.size.width - queueWidth - (queueWidth > 0 ? metrics.itemSpacing : 0))
            HStack(alignment: .top, spacing: metrics.itemSpacing) {
                if model.windows.indices.contains(model.selectedIndex) {
                    let window = model.windows[model.selectedIndex]
                    VStack(alignment: .leading, spacing: 12) {
                        thumbnail(window, index: model.selectedIndex, width: stageWidth, height: max(40, geometry.size.height - metrics.flowInformationHeight))
                        HStack(spacing: 10) {
                            appIcon(window, size: 32 * model.size.scale)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(window.displayTitle).font(.system(size: metrics.flowTitleFont, weight: .medium)).lineLimit(1)
                                HStack(spacing: 8) { Text(window.applicationName); spaceLabel(window) }
                                    .font(.system(size: metrics.captionFont)).foregroundStyle(palette.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }.frame(width: stageWidth)
                }
                if queueWidth > 0 {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                                    HStack(spacing: 8) {
                                        Text("\(index + 1)").monospacedDigit().foregroundStyle(palette.tertiary).frame(width: 14)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(window.displayTitle).fontWeight(.medium).lineLimit(1)
                                            spaceLabel(window).foregroundStyle(palette.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: metrics.captionFont))
                                    .padding(.horizontal, 10)
                                    .frame(height: metrics.flowQueueRowHeight)
                                    .background(TaberChoiceSurface(selected: index == model.selectedIndex, radius: 8))
                                    .id(window.id)
                                    .accessibilityAddTraits(index == model.selectedIndex ? .isSelected : [])
                                }
                            }
                        }.onAppear { scroll(proxy) }.onChange(of: model.selectedIndex) { _, _ in scroll(proxy) }
                    }.frame(width: queueWidth)
                }
            }
        }.padding(.horizontal, metrics.contentHorizontalPadding).padding(.top, metrics.contentBottomPadding)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.windows.isEmpty ? 0 : model.selectedIndex + 1)/\(model.windows.count)")
                .monospacedDigit().accessibilityLabel("Janela \(model.selectedIndex + 1) de \(model.windows.count)")
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(model.style.directionalHint)
                    Text(model.isSearchDetached ? "↩ abrir" : model.isSearching && model.keepSearchOpen ? "Solte ⌘ para digitar" : "Solte ⌘ para abrir")
                    Text("Esc cancelar")
                }
                Text(model.isSearchDetached ? "↩ abrir" : "⌘ Tab")
            }
        }
        .font(.system(size: metrics.headerFont)).foregroundStyle(palette.secondary)
        .padding(.horizontal, metrics.headerHorizontalPadding)
        .frame(height: metrics.headerHeight)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.accent)
            Text(model.searchQuery.isEmpty ? "Buscar aplicativo ou janela" : model.searchQuery)
                .foregroundStyle(model.searchQuery.isEmpty ? palette.secondary : palette.primary).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(model.windows.count)").monospacedDigit().foregroundStyle(palette.tertiary)
        }.font(.system(size: metrics.titleFont))
            .padding(.horizontal, metrics.contentHorizontalPadding + 8)
            .frame(height: metrics.searchBarHeight)
            .background(palette.surface)
            .accessibilityLabel("Busca: \(model.searchQuery). \(model.windows.count) resultados")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .light))
            Text("Nenhuma janela encontrada").font(.system(size: metrics.titleFont, weight: .medium))
            Text("Tente outro nome.").font(.system(size: metrics.captionFont)).foregroundStyle(palette.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func appIcon(_ window: WindowInfo, size: CGFloat) -> some View {
        Image(nsImage: window.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!)
            .resizable().scaledToFit().frame(width: size, height: size)
    }
    private func spaceLabel(_ window: WindowInfo) -> some View {
        Label(window.spaceLabel, systemImage: window.spaceState.symbolName).lineLimit(1).help(window.spaceDescription)
    }
    @ViewBuilder private func thumbnail(_ window: WindowInfo, index: Int, width: CGFloat, height: CGFloat) -> some View {
        if model.isDemo {
            DemoWindowContent(index: index % 3).frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            WindowThumbnail(window: window, width: width, height: height, generation: model.thumbnailGeneration)
        }
    }
}

private struct WindowThumbnail: View {
    @Environment(\.taberThemePalette) private var palette
    let window: WindowInfo
    let width: CGFloat
    let height: CGFloat
    let generation: UInt
    @State private var result: WindowThumbnailResult?
    var body: some View {
        ZStack {
            palette.thumbnailBackground
            if case let .image(image) = result { Image(nsImage: image).resizable().scaledToFit() }
            else {
                VStack(spacing: 8) {
                    Image(systemName: result == nil ? "macwindow" : "rectangle.slash").font(.system(size: 24, weight: .light))
                    Text(message).font(.system(size: 11)).multilineTextAlignment(.center)
                }.foregroundStyle(palette.secondary).padding(12)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(palette.border.opacity(0.5)) }
        .task(id: "\(window.ownerPID):\(window.id):\(generation):\(width):\(height)") {
            result = nil
            let captured = await WindowThumbnailService.shared.thumbnail(for: window, targetSize: CGSize(width: width, height: height), generation: generation)
            guard !Task.isCancelled else { return }
            result = captured
        }
    }
    private var message: String {
        switch result {
        case nil: "Preparando prévia"
        case .permissionRequired: "Autorize Gravação de Tela nas configurações"
        case .unavailable: window.isMinimized ? "Janela minimizada" : "Prévia indisponível"
        case .image: ""
        }
    }
}
